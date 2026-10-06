import SwiftUI

/// Say a quick list or reminder and save it as a text coin. Listening starts
/// right away; tap Done, check the words, and save. A picture can be added
/// later with Edit.
struct VoiceNoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var capture = VoiceCapture()
    @State private var text = ""
    @State private var title = ""
    @State private var accent = 0
    @State private var saving = false
    @State private var error: String?
    @State private var started = false
    /// One id for this note, so tapping Save again after a failure never makes two.
    @State private var draftId = UUID().uuidString.lowercased()
    @FocusState private var editing: Bool

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                switch capture.state {
                case .idle, .starting, .listening, .stopping:
                    listening
                case .finished:
                    review
                case .denied:
                    message(
                        icon: "mic.slash",
                        title: "Coin Purse needs the microphone",
                        detail: "Turn on Microphone and Speech Recognition for Coin Purse in Settings to make voice notes.",
                        button: "Open Settings"
                    ) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                case .unavailable:
                    message(
                        icon: "waveform.slash",
                        title: "Voice notes are not available right now",
                        detail: "Speech recognition is not ready on this iPhone. Check your connection, or try again in a moment.",
                        button: "Try again"
                    ) {
                        Task { await capture.start() }
                    }
                }
            }
            .navigationTitle("Voice note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        capture.cancel()
                        dismiss()
                    }
                    .disabled(saving)
                }
                if capture.state == .finished {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await save() } }
                                .bold()
                                .disabled(!canSave)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(saving || capture.state == .finished)
        .task {
            guard !started else { return }
            started = true
            accent = model.suggestedAccent()
            await capture.start()
        }
        .onDisappear { capture.cancel() }
    }

    // MARK: Listening

    private var listening: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if capture.transcript.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Start talking…")
                                    .font(.title.bold())
                                Text("Say a quick note or reminder, like where you parked or who to call back.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(capture.transcript)
                                .font(.title2.weight(.semibold))
                                .accessibilityIdentifier("liveTranscript")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .id("bottom")
                }
                .onChange(of: capture.transcript) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            VStack(spacing: 14) {
                Button {
                    Task { await finish() }
                } label: {
                    ZStack {
                        // Rings that swell with your voice.
                        ForEach(0..<3) { ring in
                            Circle()
                                .stroke(AccentPalette.color(accent).opacity(0.35 - Double(ring) * 0.1), lineWidth: 2)
                                .frame(width: 96, height: 96)
                                .scaleEffect(1 + CGFloat(capture.level) * (0.35 + CGFloat(ring) * 0.3))
                        }
                        Circle()
                            .fill(AccentPalette.color(accent))
                            .frame(width: 96, height: 96)
                            .shadow(color: AccentPalette.color(accent).opacity(0.6), radius: 18)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 180, height: 180)
                    .animation(.easeOut(duration: 0.12), value: capture.level)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
                .accessibilityIdentifier("stopRecording")
                .disabled(capture.state != .listening)

                Text(capture.state == .listening ? "Listening.  Tap when you are done."
                     : capture.state == .stopping ? "Finishing…" : "Getting ready…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: Review

    private var review: some View {
        Form {
            Section {
                TextField("Your note", text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(3...14)
                    .focused($editing)
                    .accessibilityIdentifier("voiceText")
                Button {
                    Task { await keepTalking() }
                } label: {
                    Label("Keep talking", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            } footer: {
                if text.isEmpty {
                    Text("Coin Purse did not catch that.  Tap Keep talking to try again.")
                }
            }

            Section {
                TextField("Title (optional)", text: $title)
                    .accessibilityIdentifier("voiceTitle")
                    .submitLabel(.done)
            } footer: {
                if title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Leave the title blank and it is saved as \(model.nextDefaultTitle()).  You can add a picture later with Edit.")
                } else {
                    Text("You can add a picture later with Edit.")
                }
            }

            Section("Color") {
                AccentPicker(accent: $accent)
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .disabled(saving)
        .scrollDismissesKeyboard(.interactively)
    }

    private func message(icon: String, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(button, action: action).buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxHeight: .infinity)
    }

    // MARK: Actions

    private func finish() async {
        await capture.finish()
        // Saved just as you said it.
        text = capture.transcript
    }

    private func keepTalking() async {
        // Continue from what is on screen now, including any edits.
        capture.transcript = text
        await capture.start()
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await model.saveCoinDetails(
                id: draftId,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: text.trimmingCharacters(in: .whitespacesAndNewlines),
                accent: accent
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription + " Tap Save to try again."
        }
    }
}

/// The six color dots, shared by the editor and voice notes.
struct AccentPicker: View {
    @Binding var accent: Int

    var body: some View {
        HStack {
            ForEach(AccentPalette.hex.indices, id: \.self) { i in
                Button { accent = i } label: {
                    Circle()
                        .fill(AccentPalette.color(i))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: accent == i ? 3 : 0))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AccentPalette.names[i])
                .accessibilityAddTraits(accent == i ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
