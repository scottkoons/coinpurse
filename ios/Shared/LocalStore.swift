import Foundation

/// The purse, kept on this iPhone: the coins in one small file and each
/// picture as a JPEG beside it, in the space the app shares with Share to
/// Coin Purse. Nothing leaves the phone, so everything works with no signal.
/// Every change hands back the coin as it now is.
nonisolated struct LocalStore: Sendable {
    static let appGroup = "group.com.yetignome.coinpurse"

    /// Where the purse lives (shared with the Share extension).
    static var folder: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Purse", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Pictures", isDirectory: true),
                                                 withIntermediateDirectories: true)
        return folder
    }

    private static var coinsFile: URL { folder.appendingPathComponent("coins.json") }

    // MARK: Coins

    /// Every coin, front of the purse first (archived ones are kept in the list too).
    func coins() async throws -> [Coin] {
        try Self.coordinated(writing: false) { Self.read($0) }
    }

    /// Makes the coin, or returns it unchanged if it already exists (so a
    /// repeated save never makes two). A blank title gets the next Coin number.
    func createCoin(id: String, title: String, notes: String, accent: Int, pin: Pin? = nil, hidden: Bool = false) async throws -> Coin {
        try Self.change { coins in
            if let existing = coins.first(where: { $0.id == id }) { return existing }
            let name = title.isEmpty ? Self.nextDefaultTitle(after: coins) : title
            let coin = Coin(id: id, title: name, notes: notes, accent: accent, pin: pin, hidden: hidden, at: Self.now)
            // New coins go on top of the purse.
            coins.insert(coin, at: 0)
            return coin
        }
    }

    /// Sets, moves or (with nil) removes a coin's map pin.
    func setPin(id: String, pin: Pin?) async throws -> Coin {
        try Self.edit(id) { $0.pin = pin }
    }

    /// A blank title keeps the one it has.
    func updateCoin(id: String, title: String, notes: String, accent: Int, hidden: Bool? = nil) async throws -> Coin {
        try Self.edit(id) { coin in
            if !title.isEmpty { coin.title = title }
            coin.notes = notes
            coin.accent = accent
            if let hidden { coin.hidden = hidden }
        }
    }

    func setArchived(id: String, _ archived: Bool) async throws -> Coin {
        try Self.edit(id) { $0.archived = archived }
    }

    func setHidden(id: String, _ hidden: Bool) async throws -> Coin {
        try Self.edit(id) { $0.hidden = hidden }
    }

    /// The coin and its pictures, gone from the phone.
    func deleteCoin(id: String) async throws {
        let removed: Coin? = try Self.change { coins in
            guard let i = coins.firstIndex(where: { $0.id == id }) else { return nil }
            return coins.remove(at: i)
        }
        removed?.pictures.forEach { picture in
            Self.removeFile(picture.key)
            if let video = picture.video { Self.removeFile(video) }
        }
    }

    /// The coins in this order; any not listed keep their order after them.
    func reorder(ids: [String]) async throws -> [Coin] {
        try Self.change { coins in
            let byId = Dictionary(coins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let listed = Set(ids)
            coins = ids.compactMap { byId[$0] } + coins.filter { !listed.contains($0.id) }
            return coins
        }
    }

    // MARK: Pictures

    /// The coin's first picture (the one on its card), new or in place of the
    /// old one. With `video`, it is a video and `jpeg` a still from it.
    func uploadMainPicture(coinId: String, jpeg: Data, video: URL? = nil) async throws -> Coin {
        let path = try Self.savePicture(jpeg)
        let videoPath: String?
        do { videoPath = try video.map(Self.saveVideo) } catch { Self.removeFile(path); throw error }
        var old: [String?] = []
        do {
            let coin = try Self.edit(coinId) { coin in
                old = [coin.imagePath, coin.videoPath]
                coin.imageUrl = path
                coin.imagePath = path
                coin.videoPath = videoPath
            }
            old.compactMap { $0 }.forEach(Self.removeFile)
            return coin
        } catch {
            Self.removeFile(path)
            if let videoPath { Self.removeFile(videoPath) }
            throw error
        }
    }

    /// Another picture (or, with `video`, a video and a still from it).
    func addPicture(coinId: String, jpeg: Data, video: URL? = nil) async throws -> Coin {
        let path = try Self.savePicture(jpeg)
        let videoPath: String?
        do { videoPath = try video.map(Self.saveVideo) } catch { Self.removeFile(path); throw error }
        do {
            return try Self.edit(coinId) { coin in
                guard coin.pictures.count < Config.maxExtraPictures + 1 else {
                    throw PurseError.failed("A coin holds at most \(Config.maxExtraPictures + 1) pictures")
                }
                coin.attachments.append(Attachment(id: UUID().uuidString.lowercased(), imageUrl: path, imagePath: path,
                                                   videoPath: videoPath))
            }
        } catch {
            Self.removeFile(path)
            if let videoPath { Self.removeFile(videoPath) }
            throw error
        }
    }

    func replacePicture(coinId: String, attachmentId: String, jpeg: Data) async throws -> Coin {
        let path = try Self.savePicture(jpeg)
        var old: String?
        do {
            let coin = try Self.edit(coinId) { coin in
                guard let i = coin.attachments.firstIndex(where: { $0.id == attachmentId }) else { throw PurseError.pictureGone }
                old = coin.attachments[i].imagePath
                coin.attachments[i].imageUrl = path
                coin.attachments[i].imagePath = path
            }
            if let old { Self.removeFile(old) }
            return coin
        } catch {
            Self.removeFile(path)
            throw error
        }
    }

    func deletePicture(coinId: String, attachmentId: String) async throws -> Coin {
        var old: Attachment?
        let coin = try Self.edit(coinId) { coin in
            guard let i = coin.attachments.firstIndex(where: { $0.id == attachmentId }) else { throw PurseError.pictureGone }
            old = coin.attachments.remove(at: i)
        }
        [old?.imagePath, old?.videoPath].compactMap { $0 }.forEach(Self.removeFile)
        return coin
    }

    /// Where a picture's file is.
    func url(for picture: Picture) -> URL? {
        Self.folder.appendingPathComponent(picture.key)
    }

    /// Where a video's file is (nil for a plain picture).
    func videoURL(for picture: Picture) -> URL? {
        picture.video.map { Self.folder.appendingPathComponent($0) }
    }

    // MARK: Adding whole coins

    /// Saves a picture brought from somewhere else and says where it is, for a
    /// coin about to be added with `add(_:)`.
    func keepPicture(_ jpeg: Data) throws -> String { try Self.savePicture(jpeg) }

    /// Coins that arrive whole (a UI test's sample purse): on top, in their
    /// order, skipping any this phone already has.
    func add(_ arriving: [Coin]) async throws {
        try Self.change { coins in
            let known = Set(coins.map(\.id))
            coins = arriving.filter { !known.contains($0.id) } + coins
        }
    }

    #if DEBUG
    /// UI tests start with an empty purse.
    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
    #endif

    // MARK: Plumbing

    static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// "Coin 3": one more than the highest such number in the purse.
    static func nextDefaultTitle(after coins: [Coin]) -> String {
        let numbers = coins.compactMap { coin -> Int? in
            let t = coin.title.trimmingCharacters(in: .whitespaces)
            // Up to nine digits: a title such as "Coin 9223372036854775807"
            // is a name, not a number to count on.
            let digits = t.dropFirst(5)
            guard t.hasPrefix("Coin "), (1...9).contains(digits.count),
                  digits.allSatisfy(\.isASCII), let n = Int(digits) else { return nil }
            return n
        }
        return "Coin \((numbers.max() ?? 0) + 1)"
    }

    /// One coin changed in place; it must exist.
    private static func edit(_ id: String, _ change: (inout Coin) throws -> Void) throws -> Coin {
        try self.change { coins in
            guard let i = coins.firstIndex(where: { $0.id == id }) else { throw PurseError.gone }
            try change(&coins[i])
            coins[i].updatedAt = now
            return coins[i]
        }
    }

    /// Read, change and write the list as one step, so the app and the Share
    /// extension never write over each other's changes.
    @discardableResult
    private static func change<T>(_ edit: (inout [Coin]) throws -> T) throws -> T {
        try coordinated(writing: true) { url in
            var coins = read(url)
            let result = try edit(&coins)
            try write(coins, to: url)
            return result
        }
    }

    private static func coordinated<T>(writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var outcome: Result<T, Error> = .failure(PurseError.failed("Could not open the purse on this iPhone."))
        var coordination: NSError?
        let coordinator = NSFileCoordinator()
        let file = coinsFile
        if writing {
            coordinator.coordinate(writingItemAt: file, options: .forMerging, error: &coordination) { url in
                outcome = Result { try body(url) }
            }
        } else {
            coordinator.coordinate(readingItemAt: file, options: [], error: &coordination) { url in
                outcome = Result { try body(url) }
            }
        }
        if coordination != nil { throw PurseError.failed("Could not open the purse on this iPhone.") }
        return try outcome.get()
    }

    private static func read(_ url: URL) -> [Coin] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Coin].self, from: data)) ?? []
    }

    private static func write(_ coins: [Coin], to url: URL) throws {
        do {
            let data = try JSONEncoder().encode(coins)
            // Protected while the phone is locked after a restart.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw PurseError.failed("Could not save on this iPhone. Is its storage full?")
        }
        #if DEBUG
        TestMirror.send(coins)
        #endif
    }

    private static func savePicture(_ jpeg: Data) throws -> String {
        let path = "Pictures/\(UUID().uuidString.lowercased()).jpg"
        do {
            try jpeg.write(to: folder.appendingPathComponent(path),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw PurseError.failed("Could not save the picture on this iPhone. Is its storage full?")
        }
        return path
    }

    /// Moves a recorded video into the purse; where it is now.
    private static func saveVideo(_ source: URL) throws -> String {
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let path = "Pictures/\(UUID().uuidString.lowercased()).\(ext)"
        let target = folder.appendingPathComponent(path)
        do {
            try FileManager.default.moveItem(at: source, to: target)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                   ofItemAtPath: target.path)
        } catch {
            throw PurseError.failed("Could not save the video on this iPhone. Is its storage full?")
        }
        return path
    }

    private static func removeFile(_ path: String) {
        // Only files of the purse (never a path that leads anywhere else).
        guard path.hasPrefix("Pictures/"), !path.contains("..") else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(path))
    }
}

#if DEBUG
/// UI tests check what was saved: each change is also sent to the local test
/// server (only when the app was started with one), which hands it to the test.
nonisolated enum TestMirror {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent = 0

    static func send(_ coins: [Coin]) {
        guard let base = ProcessInfo.processInfo.environment["COINPURSE_BASE_URL"],
              let url = URL(string: base + "/__test/state"),
              let list = try? JSONEncoder().encode(coins),
              let json = try? JSONSerialization.jsonObject(with: list) else { return }
        lock.lock()
        sent += 1
        // Later than anything sent before, even by an earlier launch.
        let number = Date().timeIntervalSince1970 * 1000 + Double(sent % 1000) / 1000
        lock.unlock()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Numbered, so an older copy that arrives late never replaces a newer one.
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["number": number, "coins": json])
        URLSession.shared.dataTask(with: request).resume()
    }
}
#endif

/// What can go wrong keeping the purse on the phone.
nonisolated enum PurseError: LocalizedError {
    /// The coin is gone (deleted a moment before).
    case gone
    /// One picture is gone; its coin is still there.
    case pictureGone
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .gone: return "This coin was deleted."
        case .pictureGone: return "This picture was removed."
        case .failed(let message): return message
        }
    }
}
