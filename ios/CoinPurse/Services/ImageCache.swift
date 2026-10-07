import UIKit

/// Keeps downloaded pictures in memory and on disk, keyed by the picture's
/// storage path (which changes whenever the picture changes), so signed links
/// can expire without forcing a re-download.
actor ImageCache {
    static let shared = ImageCache()

    /// NSCache is safe to use from any thread.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private let folder: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Bumped by removeAll (sign out), so a download that was already on its
    /// way cannot put a picture back afterwards.
    private var generation = 0

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.countLimit = 120
    }

    private func file(for key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(key.hashValue)
        return folder.appendingPathComponent(String(safe.suffix(200)))
    }

    /// A picture already in memory, right away (no waiting), so a card that is
    /// drawn again shows its picture on the first frame instead of flashing.
    nonisolated func inMemory(_ key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func cached(_ key: String) -> UIImage? {
        if let img = memory.object(forKey: key as NSString) { return img }
        if let data = try? Data(contentsOf: file(for: key)), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    /// Raw bytes for sharing or editing (downloads if needed).
    func data(key: String, url: URL) async -> Data? {
        if let data = try? Data(contentsOf: file(for: key)) { return data }
        _ = await image(key: key, url: url)
        return try? Data(contentsOf: file(for: key))
    }

    func image(key: String, url: URL) async -> UIImage? {
        if let img = cached(key) { return img }
        if let task = inFlight[key] { return await task.value }
        let target = file(for: key)
        let mine = generation
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            // Saved only if the cache was not emptied meanwhile (this runs on
            // the cache, so removeAll cannot slip in between check and write).
            await self.keep(data, img, at: target, key: key, generation: mine)
            return img
        }
        inFlight[key] = task
        let img = await task.value
        if generation == mine { inFlight[key] = nil }
        return img
    }

    private func keep(_ data: Data, _ img: UIImage, at target: URL, key: String, generation mine: Int) {
        guard generation == mine else { return }
        try? data.write(to: target, options: .atomic)
        memory.setObject(img, forKey: key as NSString)
    }

    /// Store a picture we just uploaded so it shows instantly.
    func store(_ data: Data, key: String) {
        try? data.write(to: file(for: key), options: .atomic)
        if let img = UIImage(data: data) { memory.setObject(img, forKey: key as NSString) }
    }

    func removeAll() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
