import SwiftUI
import UIKit

/// All app state: who is signed in and the coins in their purse.
@Observable
final class AppModel {
    enum Phase { case loading, signedOut, signedIn }

    var phase: Phase = .loading
    var email: String = ""
    var coins: [Coin] = []
    var isRefreshing = false
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
        guard token != nil else {
            phase = .signedOut
            return
        }
        email = Self.emailInToken(token) ?? ""
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
        phase = .signedIn
        await refresh()
    }

    func signOut() async {
        Keychain.deleteToken()
        token = nil
        coins = []
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
        guard token != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await api.coins()
            coins = list.coins
            if let e = list.email { email = e }
        } catch {
            await handle(error)
        }
    }

    func coin(_ id: String) -> Coin? { coins.first { $0.id == id } }

    /// Create the coin if it does not exist yet, otherwise update its text and color.
    /// Safe to repeat: the server treats a second create with the same id as a no-op.
    @discardableResult
    func saveCoinDetails(id: String, title: String, notes: String, accent: Int) async throws -> Coin {
        let coin: Coin
        if self.coin(id) == nil {
            let created = try await api.createCoin(id: id, title: title, notes: notes, accent: accent)
            // If the create was a retry, make sure the text is current.
            coin = (created.title == title && created.notes == notes && created.accent == accent)
                ? created
                : try await api.updateCoin(id: id, title: title, notes: notes, accent: accent)
        } else {
            coin = try await api.updateCoin(id: id, title: title, notes: notes, accent: accent)
        }
        upsert(coin)
        return coin
    }

    func uploadMainPicture(coinId: String, jpeg: Data) async throws {
        let coin = try await api.uploadMainPicture(coinId: coinId, jpeg: jpeg)
        cacheUpload(jpeg, key: coin.imagePath)
        upsert(coin)
    }

    func uploadExtraPicture(coinId: String, jpeg: Data) async throws {
        let coin = try await api.addPicture(coinId: coinId, jpeg: jpeg)
        cacheUpload(jpeg, key: coin.attachments.last?.imagePath)
        upsert(coin)
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
            coin = try await api.replacePicture(coinId: coinId, attachmentId: attId, jpeg: jpeg)
            cacheUpload(jpeg, key: coin.attachments.first { $0.id == attId }?.imagePath)
        } else {
            coin = try await api.uploadMainPicture(coinId: coinId, jpeg: jpeg)
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
        let before = coins
        coins.removeAll { $0.id == id }
        do {
            try await api.deleteCoin(id: id)
            show("Deleted")
        } catch {
            coins = before
            await handle(error)
        }
    }

    /// Persist a new order (front of the stack first).
    func reorder(_ ids: [String]) async {
        let byId = Dictionary(uniqueKeysWithValues: coins.map { ($0.id, $0) })
        coins = ids.compactMap { byId[$0] }
        do {
            coins = try await api.reorder(ids: ids)
        } catch {
            await handle(error)
        }
    }

    func url(for picture: Picture) -> URL? { api.url(for: picture) }

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

    func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
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
