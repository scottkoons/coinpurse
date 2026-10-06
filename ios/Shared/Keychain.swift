import Foundation
import Security

/// Stores the session token in the Keychain, on this device only. It lives in
/// a group shared with the Share extension, so "Share to Coin Purse" from any
/// app is already signed in.
nonisolated enum Keychain {
    private static let service = "com.yetignome.coinpurse"
    private static let account = "session"
    /// Team ID prefix + group name, as in both targets' entitlements.
    private static let sharedGroup = "MAWR9G7Y7A.com.yetignome.coinpurse.shared"

    static func saveToken(_ token: String) {
        deleteToken()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        query[kSecAttrAccessGroup as String] = sharedGroup
        if SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            // No shared group (unsigned builds): keep it private to the app.
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func loadToken() -> String? {
        // Finds it in the shared group or, from older versions, the app's own.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let appGroup = "MAWR9G7Y7A.com.yetignome.coinpurse"

    /// Moves a token saved by an older version into the shared group, once.
    /// The shared copy is added before the old one is removed, so being
    /// stopped half way never signs anyone out.
    static func shareExistingToken() {
        var shared: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: sharedGroup,
        ]
        if SecItemCopyMatching(shared as CFDictionary, nil) == errSecSuccess { return }
        guard let token = loadToken() else { return }
        shared[kSecValueData as String] = Data(token.utf8)
        shared[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(shared as CFDictionary, nil) == errSecSuccess else { return }
        let old: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: appGroup,
        ]
        SecItemDelete(old as CFDictionary)
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Removes it from every group this app can see.
        SecItemDelete(query as CFDictionary)
    }
}
