import Foundation
import Security
import CryptoKit

@MainActor enum AICredentialStore {
    private static let service = "com.sonivo.ai.credentials"
    // Fingerprints only: reject common keys shipped in old builds during migration.
    private static let retired = Set(["97e00d014cf55dfed177741e5f50567a27e7e47ac4037c00590f1f6ec2e3f368","a16a013166d1e7643af7278bac8924e4cb9d6d898de1c30ac5723927ab3aa013"])
    static func read(_ provider: AIProvider) -> String {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecAttrAccount as String:provider.rawValue,
            kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data:data,encoding:.utf8) ?? ""
    }
    static func write(_ key: String, provider: AIProvider) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecAttrAccount as String:provider.rawValue]
        if clean.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
            return
        }
        let data = Data(clean.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(update)) }
        var insert = query; insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary,nil)
        guard status == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
    }
    static func migrate(_ provider: AIProvider, legacyKey: String) {
        guard let old = UserDefaults.standard.string(forKey:legacyKey) else { return }
        let fingerprint = SHA256.hash(data:Data(old.utf8)).map { String(format:"%02x",$0) }.joined()
        if !old.isEmpty, !retired.contains(fingerprint), read(provider).isEmpty {
            do { try write(old,provider:provider) } catch { return } // Keep personal data if Keychain failed.
        }
        UserDefaults.standard.removeObject(forKey:legacyKey)
    }
}
