import Foundation

// Protocol compatibility with MarshalX/yandex-music-api; see docs/yandex-personal-auth.md.
// These are the upstream public OAuth client identifiers, NOT a user's music token.
@MainActor
final class YandexDeviceAuthClient {
    static let shared = YandexDeviceAuthClient()
    private let session: URLSession
    private let clientID: String
    private let clientSecret: String

    init(session: URLSession? = nil, clientID: String = "23cabbbdc6cd418abb4b39c32c41195d", clientSecret: String = "53bc75238f0c4d08a118e51fe9203300") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        self.session = session ?? URLSession(configuration: configuration)
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    func requestCode() async throws -> YandexDeviceCode {
        let data = try await post(path: "device/code", fields: [
            "client_id": clientID, "device_id": UUID().uuidString,
            "device_name": "Sonivo (unofficial music client)"
        ])
        let code = try JSONDecoder().decode(YandexDeviceCode.self, from: data)
        guard !code.device_code.isEmpty, !code.user_code.isEmpty,
              code.expires_in > 0, code.expires_in <= 3600,
              code.interval > 0, code.interval <= 300,
              code.verificationURL != nil else { throw YandexAuthError.invalidResponse }
        return code
    }

    func pollToken(code: String) async throws -> YandexOAuthToken {
        let data = try await post(path: "token", fields: [
            "grant_type": "device_code", "code": code,
            "client_id": clientID, "client_secret": clientSecret
        ])
        return try decodeToken(data)
    }

    func refresh(_ refreshToken: String) async throws -> YandexOAuthToken {
        let data = try await post(path: "token", fields: [
            "grant_type": "refresh_token", "refresh_token": refreshToken,
            "client_id": clientID, "client_secret": clientSecret
        ])
        return try decodeToken(data)
    }

    private func decodeToken(_ data: Data) throws -> YandexOAuthToken {
        let token = try JSONDecoder().decode(YandexOAuthToken.self, from: data)
        guard !token.access_token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.expires_in.map({ $0 > 0 && $0.isFinite }) ?? true else {
            throw YandexAuthError.invalidResponse
        }
        return token
    }

    private func post(path: String, fields: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        let url = URL(string: "https://oauth.yandex.ru/" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = YandexOAuthForm.encode(fields)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw YandexAuthError.invalidResponse }
        if let error = try? JSONDecoder().decode(YandexOAuthFailure.self, from: data) {
            switch error.error {
            case "authorization_pending": throw YandexAuthError.pending
            case "slow_down": throw YandexAuthError.slowDown
            case "access_denied": throw YandexAuthError.denied
            case "expired_token": throw YandexAuthError.expired
            case "invalid_grant": throw YandexAuthError.rejectedToken
            default: throw YandexAuthError.unavailable
            }
        }
        guard (200...299).contains(http.statusCode) else { throw YandexAuthError.unavailable }
        return data
    }
}

nonisolated enum YandexOAuthForm {
    static func encode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
}

nonisolated struct YandexDeviceCode: Decodable, Sendable {
    let device_code: String
    let user_code: String
    let verification_url: String
    let expires_in: Double
    let interval: Double
    var verificationURL: URL? {
        guard let url = URL(string: verification_url), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil,
              ["oauth.yandex.ru", "oauth.yandex.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
    }
}

nonisolated struct YandexOAuthToken: Codable, Sendable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Double?
    let token_type: String?
}

nonisolated private struct YandexOAuthFailure: Decodable {
    let error: String
}

nonisolated enum YandexAuthError: Error, LocalizedError, Equatable {
    case pending, slowDown, denied, expired, rejectedToken, invalidResponse, unavailable
    var errorDescription: String? {
        switch self {
        case .pending: "Ожидаем подтверждение на странице Яндекса."
        case .slowDown: "Ожидаем подтверждение. Яндекс попросил проверять реже."
        case .denied: "Вход отменён на странице Яндекса. Можно попробовать снова."
        case .expired: "Время действия кода истекло. Получите новый код."
        case .rejectedToken: "Сессия истекла или была отозвана. Войдите снова."
        case .invalidResponse: "Яндекс вернул неподдерживаемый ответ. Попробуйте позже."
        case .unavailable: "Не удалось подключиться к Яндексу. Попробуйте позже."
        }
    }
}
