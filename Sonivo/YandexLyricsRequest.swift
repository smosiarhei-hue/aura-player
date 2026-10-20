import Foundation
import CryptoKit

/// Protocol contract: MarshalX/yandex-music-api tracks_lyrics / get_sign_request.
/// The signing salt is a public client constant, not a user's credential.
nonisolated enum YandexLyricsRequest {
    static func request(base: String, trackID: String, token: String, timestamp: Int) -> URLRequest? {
        guard !token.isEmpty, !trackID.isEmpty,
              trackID.utf8.allSatisfy({ (48...57).contains($0) }), timestamp >= 0,
              var components = URLComponents(string: base + "/tracks/" + trackID + "/lyrics"),
              components.scheme == "https" else { return nil }
        let key = SymmetricKey(data: Data("p93jhgh689SBReK6ghtw62".utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(
            for: Data("\(trackID)\(timestamp)".utf8), using: key)).base64EncodedString()
        components.queryItems = [URLQueryItem(name: "format", value: "LRC"),
            URLQueryItem(name: "timeStamp", value: String(timestamp)),
            URLQueryItem(name: "sign", value: signature)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        request.setValue("YandexMusic/2024.1", forHTTPHeaderField: "User-Agent")
        request.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        return request
    }
}
