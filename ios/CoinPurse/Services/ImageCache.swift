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
        // Counted by the memory a drawn picture takes (about 8 MB for a
        // 1200 x 1600 photo), so a big purse never holds a gigabyte of them.
        memory.totalCostLimit = 150 * 1024 * 1024
    }

    /// A picture already in memory, right away (no waiting), so a card that is
    /// drawn again shows its picture on the first frame instead of flashing.
    nonisolated func inMemory(_ key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    /// Reads it from its file and decodes it (off the main thread, as this
    /// is an actor), so drawing it the first time never stalls scrolling.
    func image(key: String, url: URL) -> UIImage? {
        if let img = memory.object(forKey: key as NSString) { return img }
        guard let data = try? Data(contentsOf: url), let img = Self.ready(data) else { return nil }
        keep(img, key: key)
        return img
    }

    /// A picture just saved, so it shows at once.
    func store(_ data: Data, key: String) {
        if let img = Self.ready(data) { keep(img, key: key) }
    }

    private static func ready(_ data: Data) -> UIImage? {
        guard let img = UIImage(data: data) else { return nil }
        return img.preparingForDisplay() ?? img
    }

    private func keep(_ img: UIImage, key: String) {
        let cost = img.cgImage.map { $0.bytesPerRow * $0.height }
            ?? Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        memory.setObject(img, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        memory.removeAllObjects()
    }
}
