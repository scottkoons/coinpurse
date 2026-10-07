import Foundation

nonisolated enum Config {
    /// The CoinPurse server. Debug builds can point at a local server
    /// (node test/devserver.js) through the COINPURSE_BASE_URL environment
    /// variable or user default.
    static let baseURL: URL = {
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["COINPURSE_BASE_URL"]
            ?? UserDefaults.standard.string(forKey: "COINPURSE_BASE_URL")
        if let override, let url = URL(string: override) {
            // Tests: tell the Share extension too, which iOS starts without
            // the app's environment.
            Keychain.saveDebugServer(override)
            return url
        }
        if Bundle.main.bundleURL.pathExtension == "appex" {
            if let shared = Keychain.loadDebugServer(), let url = URL(string: shared) {
                return url
            }
        } else {
            // The app is on the live server: so is the extension, never a
            // test server left over from an earlier run.
            Keychain.clearDebugServer()
        }
        #endif
        // The live server (also serves the privacy and support pages).
        return URL(string: "https://coinpurse.yetignome.com")!
    }()

    static let maxExtraPictures = 5
    /// The longest title and notes the server keeps, counted the way it
    /// counts (UTF-16 units, so most emoji count as two).
    static let maxTitle = 200
    static let maxNotes = 5000
    /// Same size limit the web app uses before uploading.
    static let maxImageWidth: CGFloat = 1200
    static let jpegQuality: CGFloat = 0.82
}

nonisolated extension String {
    /// Length as the server counts it (see Config.maxNotes).
    var serverLength: Int { utf16.count }

    /// At most `limit` of the server's units, never cutting a character
    /// (an emoji or an accented letter) in half.
    func limited(to limit: Int) -> String {
        guard serverLength > limit else { return self }
        var out = ""
        var used = 0
        for character in self {
            let size = String(character).utf16.count
            if used + size > limit { break }
            out.append(character)
            used += size
        }
        return out
    }
}
