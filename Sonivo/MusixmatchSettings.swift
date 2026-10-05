import Foundation
import Observation
import Security

/// Keeps the optional Musixmatch partner key outside UserDefaults and source control.
@Observable
@MainActor
final class MusixmatchSettings {
    static let shared = MusixmatchSettings()

    private static let service = Bundle.main.bundleIdentifier ?? "com.smoze.sonivo"
    private static let account = "musixmatch.partner-api-key"
    private static let proxyDefaultsKey = "musixmatch.proxy-base-url"

    private(set) var hasAPIKey = false
    private(set) var proxyBaseURLString = ""

    private init() {
        hasAPIKey = !(Self.readKey() ?? "").isEmpty || Self.bundleKey != nil
        proxyBaseURLString = Self.storedProxyURL ?? Self.bundleProxyURL?.absoluteString ?? ""
    }

    var hasProxyURL: Bool { proxyBaseURL != nil }

    var proxyBaseURL: URL? {
        Self.validatedProxyURL(proxyBaseURLString)
    }

    func saveProxyURL(_ rawValue: String) -> Bool {
        guard let url = Self.validatedProxyURL(rawValue) else { return false }
        let normalized = url.absoluteString
        UserDefaults.standard.set(normalized, forKey: Self.proxyDefaultsKey)
        proxyBaseURLString = normalized
        return true
    }

    func removeProxyURL() {
        UserDefaults.standard.removeObject(forKey: Self.proxyDefaultsKey)
        proxyBaseURLString = Self.bundleProxyURL?.absoluteString ?? ""
    }

    var apiKey: String {
        Self.readKey() ?? Self.bundleKey ?? ""
    }

    func saveAPIKey(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        hasAPIKey = status == errSecSuccess
        return hasAPIKey
    }

    func removeAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        SecItemDelete(query as CFDictionary)
        hasAPIKey = Self.bundleKey != nil
    }

    private static func readKey() -> String? {
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

    private static var storedProxyURL: String? {
        guard let value = UserDefaults.standard.string(forKey: proxyDefaultsKey),
              let url = validatedProxyURL(value) else { return nil }
        return url.absoluteString
    }

    private static var bundleProxyURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MUSIXMATCH_PROXY_BASE_URL") as? String else {
            return nil
        }
        return validatedProxyURL(value)
    }

    private static func validatedProxyURL(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        return url
    }

    /// Optional CI/development fallback. Production builds should use Keychain.
    private static var bundleKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MUSIXMATCH_API_KEY") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}