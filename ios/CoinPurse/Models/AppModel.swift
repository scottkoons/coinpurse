import LocalAuthentication
import SwiftUI
import UIKit

/// All app state: the coins in the purse, kept on this iPhone.
@Observable
final class AppModel {
    enum Phase { case loading, ready }

    var phase: Phase = .loading
    var coins: [Coin] = [] {
        didSet { if phase == .ready { scheduleSpotlight() } }
    }
    /// False until the purse has been read once, so a slow start shows a
    /// spinner instead of "Your purse is empty".
    var coinsLoaded = false
    var isRefreshing = false
    /// Coins from the old Coin Purse server are being brought onto this iPhone.
    private(set) var moving = false
    /// Coins being deleted right now; a refresh that started earlier must not bring them back.
    private var deleting: Set<String> = []
    /// A short message shown at the bottom of the screen.
    var toast: String?
    /// A coin just deleted or archived, with an Undo bar for a few seconds
    /// (a deleted one is deleted for good only after that).
    private(set) var undoable: Coin?
    /// What Undo would undo, and where a deleted coin was.
    private(set) var undoArchives = false
    private var undoIndex = 0
    private var undoTask: Task<Void, Never>?
    /// A coin just made in one go (a picture from the camera button, or a voice
    /// note): "Saved", with Add details and Undo, for a few seconds.
    private(set) var justSaved: Coin?
    private var justSavedTask: Task<Void, Never>?
    /// Hidden coins shown with Face ID since the app last came to the front.
    private(set) var revealed: Set<String> = []

    /// The coins in the purse, in order (archived ones are kept out of it).
    var purse: [Coin] { coins.filter { !$0.archived } }
    /// Archived coins, by title.
    var archive: [Coin] {
        coins.filter(\.archived).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Where the coins and pictures are kept: on this iPhone.
    private let store = LocalStore()
    /// Changes when a UI test empties the purse: work begun before belongs to
    /// nothing here any more and changes nothing.
    private var session = 0
    /// Counts saves, deletes and moves made on this phone, so a read that was
    /// already under way when one happened knows its list is older than what shows.
    private var changes = 0

    /// Thrown in place of a result that arrived after the purse was emptied.
    private struct SessionEnded: Error {}

    // MARK: Starting

    func start() async {
        // The Keychain outlives the app. After a delete and reinstall, an old
        // sign-in from the server days is not this phone's to use.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            Keychain.deleteToken()
            UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            session += 1
            Keychain.deleteToken()
            LocalStore.removeAll()
            await ImageCache.shared.removeAll()
            // A test's coins come from the local test server, the same way coins
            // from the old server move onto a phone.
            await signInToTestServer()
        }
        #endif
        await refresh()
        phase = .ready
        scheduleSpotlight()
        await moveFromServer()
    }

    // MARK: Moving off the old server

    /// Once: the coins kept on the old Coin Purse server come onto this iPhone,
    /// pictures and all, and the old sign-in is forgotten. With no signal it
    /// waits, and tries again whenever the app comes to the front.
    func moveFromServer() async {
        guard !moving, let token = Keychain.loadToken() else { return }
        moving = true
        defer { moving = false }
        let mine = session
        let api = APIClient(token: token)
        do {
            var arriving: [Coin] = []
            for var coin in try await api.coins().coins {
                if let link = coin.imageUrl {
                    let path = try await bring(link, from: api)
                    coin.imageUrl = path
                    coin.imagePath = path
                }
                for i in coin.attachments.indices {
                    guard let link = coin.attachments[i].imageUrl else { continue }
                    let path = try await bring(link, from: api)
                    coin.attachments[i].imageUrl = path
                    coin.attachments[i].imagePath = path
                }
                arriving.append(coin)
            }
            guard session == mine else { return }
            try await store.add(arriving)
            Keychain.deleteToken()
            Self.removeOldCopy()
            await ImageCache.shared.removeAll()
            await refresh()
            if !arriving.isEmpty { show("Your coins are now kept on this iPhone") }
        } catch APIError.unauthorized {
            show("Coins on the old server could not be moved: its sign-in expired")
        } catch {
            show("Your coins will move to this iPhone the next time it is online")
        }
    }

    /// One picture from the old server, saved on this phone; where it is now.
    private func bring(_ link: String, from api: APIClient) async throws -> String {
        let picture = Picture(id: link, url: link, key: link, attachmentId: nil)
        guard let url = api.url(for: picture) else { throw APIError.server("Bad picture address") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw APIError.network("A picture could not be brought over")
        }
        return try store.keepPicture(data)
    }

    /// The copy of the purse that older versions kept while signed in.
    private static func removeOldCopy() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("purse.json"))
    }

    #if DEBUG
    /// UI tests: the review account on the local test server, whose coins
    /// then move onto the phone like an older version's.
    private func signInToTestServer() async {
        guard ProcessInfo.processInfo.environment["COINPURSE_BASE_URL"] != nil else { return }
        let api = APIClient()
        do {
            try await api.requestCode(email: "review@example.com")
            if let token = try await api.verifyCode(email: "review@example.com", code: "123456").token {
                Keychain.saveToken(token)
            }
        } catch {
            show("Could not reach the test server")
        }
    }
    #endif

    // MARK: Coins

    /// Reads the purse kept on this phone (Share to Coin Purse may have added to it).
    func refresh() async {
        let mine = session
        isRefreshing = true
        defer { isRefreshing = false }
        for attempt in 0..<3 {
            let changesBefore = changes
            do {
                let list = try await store.coins()
                guard session == mine else { return }
                // A save, delete or move finished meanwhile, so this list may
                // be older than what shows: read again rather than undo it.
                if changes != changesBefore, attempt < 2 { continue }
                coins = list.filter { !deleting.contains($0.id) }
            } catch {
                show(error.localizedDescription)
            }
            break
        }
        if session == mine { coinsLoaded = true }
    }

    func coin(_ id: String) -> Coin? { coins.first { $0.id == id } }

    /// Create the coin if it does not exist yet, otherwise update its text and color.
    /// Safe to repeat: a second create with the same id changes nothing.
    @discardableResult
    func saveCoinDetails(id: String, title: String, notes: String, accent: Int, pin: Pin? = nil,
                         hidden: Bool = false) async throws -> Coin {
        try await guarded(id) {
            try await self.saveDetails(id: id, title: title, notes: notes, accent: accent, pin: pin, hidden: hidden)
        }
    }

    private func saveDetails(id: String, title: String, notes: String, accent: Int, pin: Pin?, hidden: Bool) async throws -> Coin {
        let coin: Coin
        if self.coin(id) == nil {
            let created = try await store.createCoin(id: id, title: title, notes: notes, accent: accent, pin: pin, hidden: hidden)
            // If the create was a retry, make sure the text is current.
            // (A blank title means it was given a name like "Coin 3".)
            coin = ((title.isEmpty || created.title == title) && created.notes == notes
                    && created.accent == accent && created.hidden == hidden)
                ? created
                : try await store.updateCoin(id: id, title: title, notes: notes, accent: accent, hidden: hidden)
        } else {
            coin = try await store.updateCoin(id: id, title: title, notes: notes, accent: accent, hidden: hidden)
        }
        // Just saved by someone looking at it: it stays shown until it is closed.
        if hidden { revealed.insert(id) }
        upsert(coin)
        return coin
    }

    /// Drops, moves or (with nil) removes the map pin on a coin.
    func setPin(_ pin: Pin?, on coinId: String) async throws {
        let coin = try await guarded(coinId) { try await self.store.setPin(id: coinId, pin: pin) }
        upsert(coin)
    }

    /// The first picture; with `video`, a video and `jpeg` a still from it.
    func uploadMainPicture(coinId: String, jpeg: Data, video: URL? = nil) async throws {
        let coin = try await guarded(coinId) { try await self.store.uploadMainPicture(coinId: coinId, jpeg: jpeg, video: video) }
        cacheUpload(jpeg, key: coin.imagePath)
        upsert(coin)
    }

    func uploadExtraPicture(coinId: String, jpeg: Data, video: URL? = nil) async throws {
        let coin = try await guarded(coinId) { try await self.store.addPicture(coinId: coinId, jpeg: jpeg, video: video) }
        cacheUpload(jpeg, key: coin.attachments.last?.imagePath)
        upsert(coin)
    }

    /// Every change to a coin goes through here: a coin that is gone (deleted
    /// in the moment before) leaves the purse too. The error still reaches the
    /// caller. Work begun before a test emptied the purse changes nothing.
    private func guarded<T>(_ coinId: String, _ op: () async throws -> T) async throws -> T {
        let mine = session
        do {
            let result = try await op()
            guard session == mine else { throw SessionEnded() }
            return result
        } catch APIError.gone {
            guard session == mine else { throw SessionEnded() }
            coins.removeAll { $0.id == coinId }
            changes += 1
            throw APIError.gone
        } catch APIError.pictureGone {
            // Only that picture is gone; the coin stays, and a refresh shows
            // what it holds now.
            guard session == mine else { throw SessionEnded() }
            Task { await refresh() }
            throw APIError.pictureGone
        }
    }

    func addPicture(to coinId: String, jpeg: Data, video: URL? = nil) async {
        let mine = session
        do {
            try await uploadExtraPicture(coinId: coinId, jpeg: jpeg, video: video)
        } catch {
            await handle(error, from: mine)
        }
    }

    /// Replace one picture (after crop or rotate).
    func replacePicture(_ picture: Picture, of coinId: String, jpeg: Data) async throws {
        let coin: Coin
        if let attId = picture.attachmentId {
            coin = try await guarded(coinId) { try await self.store.replacePicture(coinId: coinId, attachmentId: attId, jpeg: jpeg) }
            cacheUpload(jpeg, key: coin.attachments.first { $0.id == attId }?.imagePath)
        } else {
            coin = try await guarded(coinId) { try await self.store.uploadMainPicture(coinId: coinId, jpeg: jpeg) }
            cacheUpload(jpeg, key: coin.imagePath)
        }
        upsert(coin)
    }

    /// Removes one extra picture, for the editor's Save (errors go to the editor).
    func removePicture(_ picture: Picture, of coinId: String) async throws {
        guard let attId = picture.attachmentId else { return }
        do {
            upsert(try await guarded(coinId) { try await self.store.deletePicture(coinId: coinId, attachmentId: attId) })
        } catch APIError.pictureGone {
            // Already removed: that is what Save wanted.
        }
    }

    func deletePicture(_ picture: Picture, of coinId: String) async {
        guard let attId = picture.attachmentId else { return }
        let mine = session
        do {
            upsert(try await guarded(coinId) { try await self.store.deletePicture(coinId: coinId, attachmentId: attId) })
        } catch APIError.pictureGone {
            // Already removed: nothing more to do.
        } catch {
            await handle(error, from: mine)
        }
    }

    /// Every way of deleting a coin (swipe, trash can, Delete in an open coin
    /// or full screen): off the purse at once, with an Undo bar. It is deleted
    /// for good when the Undo moment passes (or the app leaves the screen), so
    /// Undo puts back the whole coin, pictures and all.
    func deleteWithUndo(_ id: String) {
        // One Undo at a time: an earlier deleted coin is deleted now.
        finishEarlierUndo()
        dismissSaved()
        guard let index = coins.firstIndex(where: { $0.id == id }) else { return }
        let removed = coins.remove(at: index)
        changes += 1
        // A refresh meanwhile must not bring it back.
        deleting.insert(id)
        undoable = removed
        undoArchives = false
        undoIndex = index
        startUndoTimer()
    }

    /// Puts a coin away in the archive, with an Undo bar for a few seconds.
    func archive(_ id: String) {
        finishEarlierUndo()
        dismissSaved()
        guard let coin = coin(id), !coin.archived else { return }
        setArchived(id, true)
        undoable = coin
        undoArchives = true
        startUndoTimer()
    }

    /// Back from the archive: it goes on top of the purse, where it shows.
    func unarchive(_ id: String) {
        guard coin(id)?.archived == true else { return }
        if undoArchives, undoable?.id == id {
            undoTask?.cancel()
            undoable = nil
        }
        setArchived(id, false)
        move(id, to: 0)
    }

    /// Changes the archived mark at once and saves it; a failure puts it back.
    private func setArchived(_ id: String, _ archived: Bool) {
        guard let i = coins.firstIndex(where: { $0.id == id }) else { return }
        coins[i].archived = archived
        changes += 1
        let mine = session
        Task {
            do {
                let saved = try await guarded(id) { try await self.store.setArchived(id: id, archived) }
                guard session == mine, coin(id)?.archived == archived else { return }
                upsert(saved)
            } catch {
                guard session == mine else { return }
                if let j = coins.firstIndex(where: { $0.id == id }), coins[j].archived == archived {
                    coins[j].archived = !archived
                    changes += 1
                }
                await handle(error, from: mine)
            }
        }
    }

    private func startUndoTimer() {
        let mine = session
        undoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, session == mine else { return }
            // This timer is done; finishing must not cancel it (and with it
            // the delete it is about to send).
            undoTask = nil
            await finishUndoable()
        }
    }

    /// Puts the deleted coin back where it was, or the archived one back in the purse.
    func undoLast() {
        undoTask?.cancel()
        guard let coin = undoable else { return }
        undoable = nil
        if undoArchives {
            // Its place in the purse never changed.
            setArchived(coin.id, false)
        } else {
            deleting.remove(coin.id)
            coins.insert(coin, at: min(undoIndex, coins.count))
            changes += 1
        }
    }

    /// Ends the Undo moment now (it passed, another coin was deleted or
    /// archived, or the app is leaving the screen): a deleted coin is deleted
    /// for good.
    func finishUndoable() async {
        guard let pending = takeUndoable() else { return }
        if !pending.archived { await deleteForGood(pending.coin, putBackAt: pending.index) }
    }

    private func finishEarlierUndo() {
        guard let earlier = takeUndoable(), !earlier.archived else { return }
        Task { await deleteForGood(earlier.coin, putBackAt: earlier.index) }
    }

    private func takeUndoable() -> (coin: Coin, index: Int, archived: Bool)? {
        undoTask?.cancel()
        guard let coin = undoable else { return nil }
        undoable = nil
        return (coin, undoIndex, undoArchives)
    }

    // MARK: Made in one go

    /// A picture (or video) straight from the camera button becomes a coin at
    /// once (named like Coin 3); the purse then opens it. Throws when it could not be saved
    /// (the caller keeps the picture so nothing is lost).
    func quickSave(picture jpeg: Data, video: URL? = nil, id: String) async throws {
        _ = try await saveCoinDetails(id: id, title: "", notes: "", accent: suggestedAccent())
        try await uploadMainPicture(coinId: id, jpeg: jpeg, video: video)
    }

    /// A new name from tapping the title. It shows at once and is saved; a
    /// failure puts the old name back. A blank name keeps the old one.
    func rename(_ id: String, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = coins.firstIndex(where: { $0.id == id }), !name.isEmpty, coins[i].title != name else { return }
        let before = coins[i]
        coins[i].title = name
        changes += 1
        let mine = session
        Task {
            do {
                try await saveCoinDetails(id: id, title: name, notes: before.notes, accent: before.accent,
                                          hidden: before.hidden)
            } catch {
                guard session == mine else { return }
                if let j = coins.firstIndex(where: { $0.id == id }), coins[j].title == name {
                    coins[j].title = before.title
                    changes += 1
                }
                await handle(error, from: mine)
            }
        }
    }

    /// Shows the Saved bar for a coin just made in one go.
    func announceSaved(_ id: String) {
        // One bar at a time: an earlier deleted coin is deleted now.
        finishEarlierUndo()
        justSavedTask?.cancel()
        justSaved = coin(id)
        let mine = session
        justSavedTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, session == mine else { return }
            justSaved = nil
        }
    }

    func dismissSaved() {
        justSavedTask?.cancel()
        justSaved = nil
    }

    /// Undo on the Saved bar: the coin just made is gone again, right away.
    func discardNew(_ id: String) {
        dismissSaved()
        guard let index = coins.firstIndex(where: { $0.id == id }) else { return }
        let coin = coins.remove(at: index)
        changes += 1
        deleting.insert(id)
        Task { await deleteForGood(coin, putBackAt: index) }
    }

    // MARK: Hidden with Face ID

    /// Hidden and not yet shown with Face ID: its notes and pictures are covered.
    func isVeiled(_ coin: Coin) -> Bool { coin.hidden && !revealed.contains(coin.id) }

    /// Asks for Face ID (or the passcode) to show a hidden coin; true when it may show.
    func reveal(_ coin: Coin) async -> Bool {
        guard isVeiled(coin) else { return true }
        let ok = await faceID(for: coin, to: "Show")
        if ok { revealed.insert(coin.id) }
        return ok
    }

    /// Deleting a hidden coin (not opened with Face ID just now) asks for Face ID
    /// first; it stays hidden either way.
    func mayDelete(_ coin: Coin) async -> Bool {
        guard isVeiled(coin) else { return true }
        return await faceID(for: coin, to: "Delete")
    }

    private func faceID(for coin: Coin, to action: String) async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestRevealNo") { return false }
        if ProcessInfo.processInfo.arguments.contains("-uiTestRevealOK") {
            // As long as a real Face ID check takes, and, as on an iPhone, the
            // app comes back from the Face ID screen and brings the purse up to date.
            try? await Task.sleep(for: .seconds(1.5))
            await refresh()
            return true
        }
        #endif
        let context = LAContext()
        // No passcode on this iPhone: there is nothing to check with.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        let title = coin.title.isEmpty ? "this coin" : "“\(coin.title)”"
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "\(action) \(title)")) ?? false
    }

    /// Leaving the app covers every hidden coin again.
    func hideRevealed() { revealed = [] }

    /// A hidden coin is shown only while it is open: closing it (or opening
    /// another) means Face ID again next time.
    func keepRevealed(only id: String?) {
        let keep = revealed.filter { $0 == id }
        if keep != revealed { revealed = keep }
    }

    /// Hiding needs something to check with: Face ID, Touch ID or a passcode.
    var canHide: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestRevealOK") { return true }
        #endif
        return AppLock.canLock
    }

    /// The lock on an open coin: hides it with Face ID, or shows it normally
    /// again. The change shows at once and is saved; a failure puts it back.
    func setHidden(_ id: String, _ hidden: Bool) {
        guard let i = coins.firstIndex(where: { $0.id == id }) else { return }
        guard !hidden || canHide else {
            show("Set a passcode on this iPhone to hide coins with Face ID")
            return
        }
        // Whoever hid it is looking at it: it stays shown until they close it.
        revealed.insert(id)
        coins[i].hidden = hidden
        changes += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        show(hidden ? "Hidden with Face ID" : "No longer hidden")
        let mine = session
        Task {
            do {
                let saved = try await guarded(id) { try await self.store.setHidden(id: id, hidden) }
                guard session == mine, coin(id)?.hidden == hidden else { return }
                upsert(saved)
            } catch {
                guard session == mine else { return }
                if let j = coins.firstIndex(where: { $0.id == id }), coins[j].hidden == hidden {
                    coins[j].hidden = !hidden
                    changes += 1
                }
                await handle(error, from: mine)
            }
        }
    }

    private func deleteForGood(_ coin: Coin, putBackAt index: Int) async {
        let mine = session
        defer { deleting.remove(coin.id) }
        do {
            try await store.deleteCoin(id: coin.id)
        } catch APIError.gone {
            // Already gone.
        } catch {
            guard session == mine else { return }
            // Could not delete it: it comes back, and says why.
            coins.insert(coin, at: min(index, coins.count))
            changes += 1
            await handle(error, from: mine)
        }
    }

    /// Persist a new order (front of the stack first).
    func reorder(_ ids: [String]) async {
        let byId = Dictionary(uniqueKeysWithValues: coins.map { ($0.id, $0) })
        let listed = Set(ids)
        // Coins added after the Rearrange sheet opened keep their place at the
        // front; archived coins stay after the purse.
        saveOrder(purse.filter { !listed.contains($0.id) } + ids.compactMap { byId[$0] }.filter { !$0.archived }
                  + coins.filter(\.archived))
    }

    /// Moves a coin to a new place in the purse (dragged in the stack) and
    /// saves the order. The purse changes at once; a failure puts it back.
    func move(_ id: String, to index: Int) {
        // Places in the purse (archived coins are not in it; they stay after it).
        let current = purse
        guard let from = current.firstIndex(where: { $0.id == id }) else { return }
        var list = current
        let moved = list.remove(at: from)
        list.insert(moved, at: min(max(index, 0), list.count))
        guard list.map(\.id) != current.map(\.id) else { return }
        saveOrder(list + coins.filter(\.archived))
    }

    /// Shows a new order at once and saves it. The saved order (or, on a
    /// failure, the order from before) is applied only if nothing else changed
    /// meanwhile; otherwise a refresh settles it, so an older result never
    /// undoes a newer move, save or delete.
    private func saveOrder(_ list: [Coin]) {
        let mine = session
        let before = coins
        coins = list
        changes += 1
        let mark = changes
        Task {
            do {
                let saved = try await store.reorder(ids: list.map(\.id))
                guard session == mine else { return }
                if changes == mark {
                    // Only the order comes from this result.  Each coin stays as it
                    // shows: a result that raced a change made at the same moment
                    // (Unarchive is a change and a move) could carry the old value
                    // and quietly undo it.
                    let known = Dictionary(uniqueKeysWithValues: coins.map { ($0.id, $0) })
                    let listed = Set(saved.map(\.id))
                    coins = saved.map { known[$0.id] ?? $0 } + coins.filter { !listed.contains($0.id) }
                } else {
                    await refresh()
                }
            } catch {
                guard session == mine else { return }
                if changes == mark { coins = before; changes += 1 } else { await refresh() }
                await handle(error, from: mine)
            }
        }
    }

    func url(for picture: Picture) -> URL? { store.url(for: picture) }

    /// A video's file (nil for a plain picture).
    func videoURL(for picture: Picture) -> URL? { store.videoURL(for: picture) }

    /// What a coin saved without a title will be called (the editor shows it).
    func nextDefaultTitle() -> String { LocalStore.nextDefaultTitle(after: coins) }

    /// The six accent colors, least-used first, like the web app.
    func suggestedAccent() -> Int {
        var counts = Array(repeating: 0, count: AccentPalette.hex.count)
        for c in purse where counts.indices.contains(c.accent) { counts[c.accent] += 1 }
        return counts.enumerated().min { $0.element < $1.element }?.offset ?? 0
    }

    // MARK: Helpers

    private func upsert(_ coin: Coin) {
        changes += 1
        if let i = coins.firstIndex(where: { $0.id == coin.id }) {
            coins[i] = coin
        } else {
            coins.insert(coin, at: 0)
        }
    }

    private func cacheUpload(_ data: Data, key: String?) {
        guard let key else { return }
        let mine = session
        Task {
            // Signed out meanwhile: the cache was just emptied; keep it so.
            guard session == mine else { return }
            await ImageCache.shared.store(data, key: key)
        }
    }

    private var toastCount = 0

    func show(_ message: String) {
        toast = message
        toastCount += 1
        let mine = toastCount
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            // Only clear our own message, not a newer one (even if it says the same thing).
            if toastCount == mine { toast = nil }
        }
    }

    // MARK: Spotlight

    private var spotlightTask: Task<Void, Never>?

    /// Many quick changes (a refresh, several uploads) become one index update.
    private func scheduleSpotlight() {
        spotlightTask?.cancel()
        spotlightTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, phase == .ready else { return }
            SpotlightIndex.update(coins)
        }
    }

    /// Reports a failure, unless the purse was emptied (for a test) since.
    private func handle(_ error: Error, from mine: Int) async {
        guard session == mine, !(error is SessionEnded) else { return }
        show(error.localizedDescription)
    }
}
