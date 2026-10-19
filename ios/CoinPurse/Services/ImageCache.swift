import UIKit

/// Keeps pictures in memory once read from their files on this iPhone, keyed
/// by the file's path (a changed picture is a new file), so a card drawn again
/// shows its picture at once.
actor ImageCache {
    static let shared = ImageCache()

    /// NSCache is safe to use from any thread, and iOS empties it when memory runs low.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()

    init() {
        memory.countLimit = 120
    }

    /// A picture already in memory, right away (no waiting), so a card that is
    /// drawn again shows its picture on the first frame instead of flashing.
    nonisolated func inMemory(_ key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    /// Reads it from its file (off the main thread, as this is an actor).
    func image(key: String, url: URL) -> UIImage? {
        if let img = memory.object(forKey: key as NSString) { return img }
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    /// A picture just saved, so it shows at once.
    func store(_ data: Data, key: String) {
        if let img = UIImage(data: data) { memory.setObject(img, forKey: key as NSString) }
    }

    func removeAll() {
        memory.removeAllObjects()
    }
}
