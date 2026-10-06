import SwiftUI
import UIKit

/// All app state: who is signed in and the coins in their purse.
@Observable
final class AppModel {
    enum Phase { case loading, signedOut, signedIn }

    var phase: Phase = .loading
    var email: String = ""
    var coins: [Coin] = [] {
        // Only a signed-in purse is kept on the phone.
        didSet { if token != nil { saveSnapshot() } }
    }
    /// False until the purse has been read once (from the phone or the server),
    /// so a slow start shows a spinner instead of "Your purse is empty".
    var coinsLoaded = false
    /// The last refresh could not reach the server; what shows is the saved copy.
    var isOffline = false
    var isRefreshing = false
    /// Coins being deleted right now; a refresh that started earlier must not bring them back.
    private var deleting: Set<String> = []
    /// A short message shown at the bottom of the screen.
    var toast: String?

    private var token: String?
    private var api: APIClient {
        APIClient(token: token) { [weak self] renewed in
            Keychain.saveToken(renewed)
            self?.token = renewed
        }
    }

    // MARK: Session

    func start() async {
        #if DEBUG
        // UI tests start signed out.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            Keychain.deleteToken()
            await ImageCache.shared.removeAll()
        }
        #endif
        // The Keychain outlives the app. After a delete and reinstall, start
        // signed out instead of reusing an old session.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            Keychain.deleteToken()
            UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
        token = Keychain.loadToken()
        // So "Share to Coin Purse" is signed in too (older versions kept it private).
        if token != nil { Keychain.shareExistingToken() }
        guard token != nil else {
            phase = .signedOut
            return
        }
        email = Self.emailInToken(token) ?? ""
        // Show the purse saved on this phone right away (works with no signal),
        // then bring it up to date.
        loadSnapshot()
        phase = .signedIn
        await refresh()
    }

    func requestCode(email: String) async throws {
        try await APIClient().requestCode(email: email)
    }

    func verifyCode(email: String, code: String) async throws {
        let result = try await APIClient().verifyCode(email: email, code: code)
        guard let newToken = result.token else {
            throw APIError.server("Please update the Coin Purse server, then try again.")
        }
        Keychain.saveToken(newToken)
        token = newToken
        self.email = result.email
        coins = []
        coinsLoaded = false
        phase = .signedIn
        await refresh()
    }

    func signOut() async {
        Keychain.deleteToken()
        token = nil
        coins = []
        coinsLoaded = false
        Self.removeSnapshot()
        SpotlightIndex.clear()
        email = ""
        await ImageCache.shared.removeAll()
        phase = .signedOut
    }

    func signOutEverywhere() async {
        do {
            let newToken = try await api.signOutEverywhere()
            Keychain.saveToken(newToken)
            token = newToken
            show("Signed out of all other devices")
        } catch {
            await handle(error)
        }
    }

    /// Returns true when the account is gone.
    func deleteAccount() async -> Bool {
        do {
            try await api.deleteAccount()
            await signOut()
            show("Your account was deleted")
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    // MARK: Coins

    func refresh() async {
        guard let asked = token else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await api.coins()
            // Signed out (or into another account) while this was on its way:
            // these coins belong to nobody here now.
            guard token == asked else { return }
            coins = list.coins.filter { !deleting.contains($0.id) }
            if let e = list.email { email = e }
            isOffline = false
        } catch APIError.network(let message) {
            // Keep showing the saved purse, and say so.
            isOffline = true
            if coins.isEmpty { show(message) }
        } catch {
            await handle(error)
        }
        coinsLoaded = true
    }

    func coin(_ id: String) -> Coin? { coins.first { $0.id == id } }

    /// Create the coin if it does not exist yet, otherwise update its text and color.
    /// Safe to repeat: the server treats a second create with the same id as a no-op.
    @discardableResult
    func saveCoinDetails(id: String, title: String, notes: String, accent: Int, pin: Pin? = nil) async throws -> Coin {
        try await guarded(id) { try await self.saveDetails(id: id, title: title, notes: notes, accent: accent, pin: pin) }
    }

    private func saveDetails(id: String, title: String, notes: String, accent: Int, pin: Pin?) async throws -> Coin {
        let coin: Coin
        if self.coin(id) == nil {
            let created = try await api.createCoin(id: id, title: title, notes: notes, accent: accent, pin: pin)
            // If the create was a retry, make sure the text is current.
            // (A blank title means the server picked a name like "Coin 3".)
            coin = ((title.isEmpty || created.title == title) && created.notes == notes && created.accent == accent)
                ? created
                : try await api.updateCoin(id: id, title: title, notes: notes, accent: accent)
        } else {
            coin = try await api.updateCoin(id: id, title: title, notes: notes, accent: accent)
        }
        upsert(coin)
        return coin
    }

    /// Drops, moves or (with nil) removes the map pin on a coin.
    func setPin(_ pin: Pin?, on coinId: String) async throws {
        let coin = try await guarded(coinId) { try await self.api.setPin(id: coinId, pin: pin) }
        upsert(coin)
    }

    func uploadMainPicture(coinId: String, jpeg: Data) async throws {
        let coin = try await guarded(coinId) { try await self.api.uploadMainPicture(coinId: coinId, jpeg: jpeg) }
        cacheUpload(jpeg, key: coin.imagePath)
        upsert(coin)
    }

    func uploadExtraPicture(coinId: String, jpeg: Data) async throws {
        let coin = try await guarded(coinId) { try await self.api.addPicture(coinId: coinId, jpeg: jpeg) }
        cacheUpload(jpeg, key: coin.attachments.last?.imagePath)
        upsert(coin)
    }

    /// Every change to a coin goes through here: an expired sign-in signs out
    /// (instead of failing forever), and a coin deleted on another device
    /// leaves this phone too. The error still reaches the caller.
    private func guarded<T>(_ coinId: String, _ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch APIError.unauthorized {
            await signOut()
            show("Please sign in again")
            throw APIError.unauthorized
        } catch APIError.gone {
            coins.removeAll { $0.id == coinId }
            throw APIError.gone
        }
    }

    func addPicture(to coinId: String, jpeg: Data) async {
        do {
            try await uploadExtraPicture(coinId: coinId, jpeg: jpeg)
        } catch {
            await handle(error)
        }
    }

    /// Replace one picture (after crop or rotate).
    func replacePicture(_ picture: Picture, of coinId: String, jpeg: Data) async throws {
        let coin: Coin
        if let attId = picture.attachmentId {
            coin = try await guarded(coinId) { try await self.api.replacePicture(coinId: coinId, attachmentId: attId, jpeg: jpeg) }
            cacheUpload(jpeg, key: coin.attachments.first { $0.id == attId }?.imagePath)
        } else {
            coin = try await guarded(coinId) { try await self.api.uploadMainPicture(coinId: coinId, jpeg: jpeg) }
            cacheUpload(jpeg, key: coin.imagePath)
        }
        upsert(coin)
    }

    func deletePicture(_ picture: Picture, of coinId: String) async {
        guard let attId = picture.attachmentId else { return }
        do {
            upsert(try await api.deletePicture(coinId: coinId, attachmentId: attId))
        } catch {
            await handle(error)
        }
    }

    func deleteCoin(_ id: String) async {
        guard let index = coins.firstIndex(where: { $0.id == id }) else { return }
        let removed = coins.remove(at: index)
        deleting.insert(id)
        defer { deleting.remove(id) }
        do {
            try await api.deleteCoin(id: id)
            show("Deleted")
        } catch APIError.gone {
            // Already gone from the server: nothing to put back.
        } catch {
            // Put back only this coin, where it was; anything added meanwhile stays.
            coins.insert(removed, at: min(index, coins.count))
            await handle(error)
        }
    }

    /// Persist a new order (front of the stack first).
    func reorder(_ ids: [String]) async {
        let before = coins
        let byId = Dictionary(uniqueKeysWithValues: coins.map { ($0.id, $0) })
        let listed = Set(ids)
        // Coins added after the Rearrange sheet opened keep their place at the front.
        coins = coins.filter { !listed.contains($0.id) } + ids.compactMap { byId[$0] }
        do {
            coins = try await api.reorder(ids: coins.map(\.id))
        } catch {
            coins = before
            await handle(error)
        }
    }

    func url(for picture: Picture) -> URL? { api.url(for: picture) }

    /// What a coin saved without a title will be called (the server decides;
    /// this matches its rule so the editor can show it).
    func nextDefaultTitle() -> String {
        let numbers = coins.compactMap { coin -> Int? in
            let t = coin.title.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("Coin "), let n = Int(t.dropFirst(5)) else { return nil }
            return n
        }
        return "Coin \((numbers.max() ?? 0) + 1)"
    }

    /// The six accent colors, least-used first, like the web app.
    func suggestedAccent() -> Int {
        var counts = Array(repeating: 0, count: AccentPalette.hex.count)
        for c in coins where counts.indices.contains(c.accent) { counts[c.accent] += 1 }
        return counts.enumerated().min { $0.element < $1.element }?.offset ?? 0
    }

    // MARK: Helpers

    private func upsert(_ coin: Coin) {
        if let i = coins.firstIndex(where: { $0.id == coin.id }) {
            coins[i] = coin
        } else {
            coins.insert(coin, at: 0)
        }
    }

    private func cacheUpload(_ data: Data, key: String?) {
        guard let key else { return }
        Task { await ImageCache.shared.store(data, key: key) }
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

    // MARK: Saved copy on the phone

    /// The purse as last seen, kept on the phone so it opens instantly and
    /// works with no signal (pictures are kept by ImageCache).
    private static var snapshotURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("purse.json")
    }

    private struct Snapshot: Codable {
        var email: String
        var coins: [Coin]
    }

    private func saveSnapshot() {
        guard phase == .signedIn, coinsLoaded || !coins.isEmpty else { return }
        scheduleSpotlight()
        let snap = Snapshot(email: email, coins: coins)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        // Protected while the phone is locked.
        try? data.write(to: Self.snapshotURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private var spotlightTask: Task<Void, Never>?

    /// Many quick changes (a refresh, several uploads) become one index update.
    private func scheduleSpotlight() {
        spotlightTask?.cancel()
        spotlightTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, phase == .signedIn else { return }
            SpotlightIndex.update(coins)
        }
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              snap.email.lowercased() == email.lowercased() else { return }
        coins = snap.coins
        coinsLoaded = true
    }

    private static func removeSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private func handle(_ error: Error) async {
        if case APIError.unauthorized = error {
            await signOut()
            show("Please sign in again")
        } else {
            show(error.localizedDescription)
        }
    }

    private static func emailInToken(_ token: String?) -> String? {
        guard let part = token?.split(separator: ".").first else { return nil }
        var b64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }
}
