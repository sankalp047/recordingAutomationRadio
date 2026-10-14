import Foundation
import Security

/// The API token is a shared secret with access to every recording, so it
/// lives in the Keychain rather than UserDefaults.
enum Keychain {
    private static let service = "net.funasia.RadioQA"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        // kSecUseDataProtectionKeychain keys the item to the app's identity
        // rather than an ACL. Without it, every ad-hoc rebuild changes the
        // signature, the ACL no longer matches, and macOS asks for the login
        // keychain password on each launch.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let s = String(data: d, encoding: .utf8)
        else { return nil }
        return s
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }
}
