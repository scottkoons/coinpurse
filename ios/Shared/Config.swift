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
    /// Same size limit the web app uses before uploading.
    static let maxImageWidth: CGFloat = 1200
    static let jpegQuality: CGFloat = 0.82
}
