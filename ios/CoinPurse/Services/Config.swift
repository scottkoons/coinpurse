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
            return url
        }
        #endif
        // TODO: replace with the production web address once confirmed.
        return URL(string: "https://coinpurse.yetignome.com")!
    }()

    static let maxExtraPictures = 5
    /// Same size limit the web app uses before uploading.
    static let maxImageWidth: CGFloat = 1200
    static let jpegQuality: CGFloat = 0.82
}
