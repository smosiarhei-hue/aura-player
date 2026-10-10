import Foundation
import Security

nonisolated struct YandexCredential: Codable, Sendable {
    let uid: Int
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    init(uid: Int, token: YandexOAuthToken, now: Date = Date(), previousRefreshToken: String? = nil) {
        self.uid = uid
        accessToken = token.access_token
        refreshToken = token.refresh_token ?? previousRefreshToken
        expiresAt = token.expires_in.map { now.addingTimeInterval($0) }
    }

    func needsRefresh(at date: Date = Date()) -> Bool {
        expiresAt.map { $0.timeIntervalSince(date) <= 60 } ?? false
    }
}

@MainActor
enum YandexCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.smoze.sonivo",
         kSecAttrAccount as String: "yandex.personal-music-session.v1"]
    }

    static func read() -> YandexCredential? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credential = try? JSONDecoder().decode(YandexCredential.self, from: data),
              credential.uid > 0, !credential.accessToken.isEmpty else { return nil }
        return credential
    }

    // Update atomically: a failed save must not destroy a previous valid credential.
    static func save(_ credential: YandexCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove() { SecItemDelete(query as CFDictionary) }
}
