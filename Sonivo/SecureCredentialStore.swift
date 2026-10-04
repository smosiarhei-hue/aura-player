import Foundation
import Security

enum SecureCredentialStore {
    private static let service = Bundle.main.bundleIdentifier ?? "com.smoze.sonivo"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else {
            return remove(account: account)
        }

        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else {
            return false
        }

        var item = lookup
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func migrateFromUserDefaults(account: String, legacyKey: String) -> String {
        if let stored = read(account: account) {
            return stored
        }

        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty else {
            return ""
        }
        guard write(legacy, account: account) else {
            return legacy
        }
        defaults.removeObject(forKey: legacyKey)
        return legacy
    }
}