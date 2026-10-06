import AVFoundation
import Speech

/// Listens to the microphone and turns speech into text with Apple's own
/// speech recognition. It runs on the iPhone when the phone supports it, so
/// there is no AI service and no cost, and the audio is never saved.
@Observable
final class VoiceCapture {
    enum State: Equatable { case idle, listening, finished, denied, unavailable }

    var state: State = .idle
    /// Everything heard so far, punctuated.
    var transcript = ""
    /// Microphone loudness from 0 to 1, for the animation.
    var level: Float = 0

    private var engine: SpeechEngine?

    /// Asks for permission the first time, then starts listening.
    func start() async {
        #if DEBUG
        // UI tests cannot speak: they pass the words in instead.
        if let fake = UserDefaults.standard.string(forKey: "uiTestVoiceText") {
            if transcript.isEmpty { transcript = fake }
            state = .listening
            return
        }
        #endif
        guard await Self.permissionsGranted() else {
            state = .denied
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            state = .unavailable
            return
        }
        let engine = SpeechEngine(recognizer: recognizer, prefix: transcript) { [weak self] text in
            Task { @MainActor in self?.transcript = text }
        } onLevel: { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        do {
            try engine.start()
            self.engine = engine
            state = .listening
        } catch {
            state = .unavailable
        }
    }

    /// Stops listening and waits a moment for the last words to come in.
    func finish() async {
        guard state == .listening else { return }
        if let engine {
            let final = await engine.stop()
            transcript = final
        }
        engine = nil
        level = 0
        state = .finished
    }

    func cancel() {
        engine?.cancel()
        engine = nil
        level = 0
        state = .idle
    }

    private static func permissionsGranted() async -> Bool {
        guard await speechAuthorization() == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// iOS answers on a background thread, so this must not be tied to the
    /// main thread (Swift stops the app if a main-thread closure runs elsewhere).
    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (done: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                done.resume(returning: status)
            }
        }
    }
}

/// The audio side, which runs off the main thread. Recognition can stop by
/// itself after a long pause, so when that happens it starts a fresh request
/// and keeps the words it already has.
private nonisolated final class SpeechEngine: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let audio = AVAudioEngine()
    private let onText: @Sendable (String) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed: String
    private var partial = ""
    private var running = false
    /// The last request has delivered its final words after stop().
    private var ended = false
    private var lastLevel = Date.distantPast
    private var finalWaiter: CheckedContinuation<Void, Never>?

    init(recognizer: SFSpeechRecognizer, prefix: String,
         onText: @escaping @Sendable (String) -> Void,
         onLevel: @escaping @Sendable (Float) -> Void) {
        self.recognizer = recognizer
        self.committed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onText = onText
        self.onLevel = onLevel
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        audio.prepare()
        try audio.start()
        lock.withLock { running = true }
        beginRequest()
    }

    /// Stops the microphone and returns the full text once the last words land.
    func stop() async -> String {
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        let req = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            running = false
            return request
        }
        req?.endAudio()
        // Give recognition up to two seconds to deliver its final result.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let already = lock.withLock { () -> Bool in
                if ended { return true }
                finalWaiter = done
                return false
            }
            if already { done.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.releaseWaiter() }
        }
        lock.withLock { task?.cancel() }
        deactivate()
        return lock.withLock { Self.join(committed, partial) }
    }

    func cancel() {
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        lock.withLock {
            running = false
            task?.cancel()
        }
        deactivate()
    }

    // MARK: Private

    private func beginRequest() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        // Keep it on the phone when the phone can do it.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.withLock {
            request = req
            partial = ""
        }
        let newTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.withLock { task = newTask }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let full = lock.withLock { () -> String in
                partial = text
                return Self.join(committed, partial)
            }
            onText(full)
            if result.isFinal { segmentEnded() }
        } else if error != nil {
            segmentEnded()
        }
    }

    /// One recognition request finished: keep its words, and start another
    /// if we are still listening.
    private func segmentEnded() {
        let keepGoing = lock.withLock { () -> Bool in
            committed = Self.join(committed, partial)
            partial = ""
            if !running { ended = true }
            return running
        }
        if keepGoing {
            beginRequest()
        } else {
            releaseWaiter()
        }
    }

    private func releaseWaiter() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { finalWaiter = nil }
            return finalWaiter
        }
        waiter?.resume()
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
        // Loudness for the animation, about 20 times a second.
        let now = Date()
        guard now.timeIntervalSince(lastLevel) > 0.05, let samples = buffer.floatChannelData?[0] else { return }
        lastLevel = now
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        // Speech sits around 0.01 to 0.2; map it to 0...1 on a log scale.
        let db = 20 * log10(max(rms, 0.000_01))
        onLevel(min(1, max(0, (db + 50) / 40)))
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

}
