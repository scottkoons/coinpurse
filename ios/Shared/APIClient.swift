import Foundation

enum APIError: LocalizedError {
    case unauthorized
    /// The coin no longer exists (deleted on another device).
    case gone
    /// One picture is gone (removed on another device); its coin is still there.
    case pictureGone
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your sign-in expired. Please sign in again."
        case .gone: return "This coin was deleted on another device."
        case .pictureGone: return "This picture was removed on another device."
        case .server(let message): return message
        case .network(let message): return message
        }
    }
}

/// Talks to the same server and endpoints as the web app.
struct APIClient {
    var baseURL: URL = Config.baseURL
    var token: String?
    /// The server sends a fresh session token about once a week; keep it so
    /// the app never gets signed out while it is in use.
    var onTokenRenewed: ((String) -> Void)?

    // MARK: Sign-in

    func requestCode(email: String) async throws {
        _ = try await send("POST", "/api/auth/request-link", json: ["email": email]) as Empty
    }

    struct VerifyResult: Decodable { let token: String?; let email: String }

    func verifyCode(email: String, code: String) async throws -> VerifyResult {
        try await send("POST", "/api/auth/verify-code", json: ["email": email, "code": code])
    }

    // MARK: Account

    func deleteAccount() async throws {
        _ = try await send("DELETE", "/api/account") as Empty
    }

    struct TokenResult: Decodable { let token: String }

    func signOutEverywhere() async throws -> String {
        let r: TokenResult = try await send("POST", "/api/account/signout-all")
        return r.token
    }

    // MARK: Coins

    struct CoinList: Decodable { let coins: [Coin]; let email: String? }
    struct CoinResult: Decodable { let coin: Coin }

    func coins() async throws -> CoinList {
        // Short: with a weak signal the purse already shows its saved copy,
        // and saying "Offline" soon beats a long wait.
        try await send("GET", "/api/coins", timeout: 15)
    }

    func createCoin(id: String, title: String, notes: String, accent: Int, pin: Pin? = nil, hidden: Bool = false) async throws -> Coin {
        var body: [String: Any] = ["id": id, "title": title, "notes": notes, "accent": accent, "hidden": hidden]
        if let pin { body["pin"] = pin.json }
        let r: CoinResult = try await send("POST", "/api/coins", json: body)
        return r.coin
    }

    /// Sets, moves or (with nil) removes a coin's map pin.
    func setPin(id: String, pin: Pin?) async throws -> Coin {
        let r: CoinResult = try await send("PUT", "/api/coins/\(id.urlPathSafe)", json: [
            "pin": pin.map { $0.json as Any } ?? NSNull(),
        ])
        return r.coin
    }

    func updateCoin(id: String, title: String, notes: String, accent: Int, hidden: Bool? = nil) async throws -> Coin {
        var body: [String: Any] = ["title": title, "notes": notes, "accent": accent]
        if let hidden { body["hidden"] = hidden }
        let r: CoinResult = try await send("PUT", "/api/coins/\(id.urlPathSafe)", json: body)
        return r.coin
    }

    /// Puts a coin away in the archive, or back in the purse.
    func setArchived(id: String, _ archived: Bool) async throws -> Coin {
        let r: CoinResult = try await send("PUT", "/api/coins/\(id.urlPathSafe)", json: ["archived": archived])
        return r.coin
    }

    func deleteCoin(id: String) async throws {
        _ = try await send("DELETE", "/api/coins/\(id.urlPathSafe)") as Empty
    }

    func reorder(ids: [String]) async throws -> [Coin] {
        let r: CoinList = try await send("POST", "/api/coins/reorder", json: ["ids": ids])
        return r.coins
    }

    // MARK: Pictures

    func uploadMainPicture(coinId: String, jpeg: Data) async throws -> Coin {
        let r: CoinResult = try await send("POST", "/api/coins/\(coinId.urlPathSafe)/image", body: jpeg, contentType: "image/jpeg")
        return r.coin
    }

    func addPicture(coinId: String, jpeg: Data) async throws -> Coin {
        let r: CoinResult = try await send("POST", "/api/coins/\(coinId.urlPathSafe)/attachments", body: jpeg, contentType: "image/jpeg")
        return r.coin
    }

    func replacePicture(coinId: String, attachmentId: String, jpeg: Data) async throws -> Coin {
        let r: CoinResult = try await send(
            "PUT", "/api/coins/\(coinId.urlPathSafe)/attachments?attId=\(attachmentId.urlQuerySafe)",
            body: jpeg, contentType: "image/jpeg")
        return r.coin
    }

    func deletePicture(coinId: String, attachmentId: String) async throws -> Coin {
        let r: CoinResult = try await send(
            "DELETE", "/api/coins/\(coinId.urlPathSafe)/attachments?attId=\(attachmentId.urlQuerySafe)")
        return r.coin
    }

    /// Picture links from the server may be relative (signed /api/img links).
    func url(for picture: Picture) -> URL? {
        URL(string: picture.url, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: Plumbing

    private struct Empty: Decodable {}
    private struct ErrorBody: Decodable { let error: String?; let code: String? }

    private func send<T: Decodable>(
        _ method: String, _ path: String,
        json: [String: Any]? = nil, body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 60
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.server("Bad address") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network("Could not reach Coin Purse. Check your connection.")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 && token != nil { throw APIError.unauthorized }
        if (status == 404 || status == 410) && path.hasPrefix("/api/coins/") {
            // The server says when only a picture is missing, not the coin.
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.code
            throw code == "PICTURE_GONE" ? APIError.pictureGone : APIError.gone
        }
        if let renewed = http?.value(forHTTPHeaderField: "X-Coinpurse-Token"), !renewed.isEmpty {
            onTokenRenewed?(renewed)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.server(message ?? "Something went wrong (\(status))")
        }
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.server("Unexpected reply from the server")
        }
    }
}

private extension String {
    var urlPathSafe: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? self }
    var urlQuerySafe: String { addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self }
}
