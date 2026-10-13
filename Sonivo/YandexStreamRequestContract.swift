import Foundation
import CryptoKit

/// Authenticated raw-file contract: the signing key must match the advertised API client.
/// Public interoperability constants, not an account credential; OAuth remains mandatory.
nonisolated enum YandexStreamRequestContract {
    static let desktopClient = "YandexMusicDesktopAppWindows/5.95.0"
    static let codecs = ["flac", "flac-mp4", "aac-mp4", "he-aac-mp4", "aac", "he-aac", "mp3"]
    static let transport = "raw" // encraw is decoded before any native player sees it.
    private static let signingKey = "kzqU4XhfCaY6B6JTHODeq5"

    static func signature(timestamp: Int, trackID: String, quality: String, codecs: [String] = Self.codecs, transport: String = Self.transport) -> String {
        let message = "\(timestamp)\(trackID)\(quality)\(codecs.joined())\(transport)"
        let key = SymmetricKey(data: Data(signingKey.utf8))
        let value = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return String(Data(value).base64EncodedString().dropLast())
    }
    static func request(base: String, trackID: String, timestamp: Int, quality: String, codecs: [String] = Self.codecs, transport: String = Self.transport) -> URLRequest? {
        guard ["raw", "encraw"].contains(transport), !codecs.isEmpty, codecs.allSatisfy(Self.codecs.contains), ["lossless", "hq", "nq"].contains(quality) else { return nil }
        guard var components = URLComponents(string: base + "/get-file-info") else { return nil }
        components.queryItems = [
            .init(name: "ts", value: String(timestamp)), .init(name: "trackId", value: trackID),
            .init(name: "quality", value: quality), .init(name: "codecs", value: codecs.joined(separator: ",")),
            .init(name: "transports", value: transport),
            .init(name: "sign", value: signature(timestamp: timestamp, trackID: trackID, quality: quality, codecs: codecs, transport: transport))
        ]
        // URLComponents permits literal + in a query. The API's form-style parser
        // treats it as a space, corrupting Base64 signatures and returning 403.
        // Escape only literal + after query-item encoding; do not double-encode %.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(desktopClient, forHTTPHeaderField: "X-Yandex-Music-Client")
        request.setValue("Sonivo/1.1 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        return request
    }
}
