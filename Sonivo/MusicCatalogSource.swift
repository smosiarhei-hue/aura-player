import Foundation

/// Catalog selection is deliberately independent of audio transport and Yandex credentials.
nonisolated enum MusicCatalogSource: String, CaseIterable, Identifiable, Sendable {
    case yandex
    case spotifyCatalog
    static let storageKey = "sonivo.search.catalog.source"
    var id: String { rawValue }
    var title: String { self == .yandex ? "Яндекс Музыка / медиатека" : "Spotify — каталог" }
    static func resolve(_ raw: String) -> Self { Self(rawValue: raw) ?? .yandex }
}

nonisolated struct SpotifyCatalogTrack: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let thumbnail: String?
    let album: String?
    let preview_url: String?
    var spotifyURL: URL? {
        guard id.count == 22, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return URL(string: "https://open.spotify.com/track/\(id)")
    }
    var artworkURLString: String? {
        guard let thumbnail, let url = URL(string: thumbnail), url.scheme == "https",
              url.user == nil, url.password == nil else { return nil }
        return thumbnail
    }
    var previewURL: URL? {
        guard let preview_url, let url = URL(string: preview_url), url.scheme == "https",
              let host = url.host?.lowercased(), host == "scdn.co" || host.hasSuffix(".scdn.co"),
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

nonisolated enum SpotifyCatalogError: LocalizedError {
    case unavailable, limited, invalidResponse
    var errorDescription: String? {
        switch self {
        case .unavailable: "Каталог Spotify временно недоступен. Попробуйте позже или выберите Яндекс в настройках."
        case .limited: "Слишком много запросов к каталогу. Подождите и повторите поиск."
        case .invalidResponse: "Каталог вернул неподдерживаемый ответ. Воспроизведение Sonivo не изменено."
        }
    }
}

/// Isolated, credential-free metadata client. No audio resolver, shared cookies or OAuth token endpoint.
actor WolfSpotifyCatalogClient {
    static let shared = WolfSpotifyCatalogClient()
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 18
            self.session = URLSession(configuration: configuration)
        }
    }
    nonisolated private struct SearchEnvelope: Decodable { let success: Bool; let results: [SpotifyCatalogTrack]? }
    nonisolated private struct TrackEnvelope: Decodable { let success: Bool; let track: SpotifyCatalogTrack? }

    func search(_ text: String) async throws -> [SpotifyCatalogTrack] {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(150))
        guard !query.isEmpty else { return [] }
        var components = URLComponents(string: "https://spotify.xwolf.space/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "track"), URLQueryItem(name: "limit", value: "20")]
        let data = try await request(components.url!, emptyOnNotFound: true)
        guard !data.isEmpty else { return [] }
        let envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        guard envelope.success, let results = envelope.results else { throw SpotifyCatalogError.invalidResponse }
        var seen = Set<String>()
        return results.filter { $0.spotifyURL != nil && seen.insert($0.id).inserted }.prefix(20).map { $0 }
    }
    func detail(_ track: SpotifyCatalogTrack) async throws -> SpotifyCatalogTrack {
        guard track.spotifyURL != nil else { throw SpotifyCatalogError.invalidResponse }
        let url = URL(string: "https://spotify.xwolf.space/api/track/\(track.id)")!
        let data = try await request(url)
        let envelope = try JSONDecoder().decode(TrackEnvelope.self, from: data)
        guard envelope.success, let detail = envelope.track, detail.id == track.id,
              detail.spotifyURL != nil else { throw SpotifyCatalogError.invalidResponse }
        return detail
    }
    private func request(_ url: URL, emptyOnNotFound: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SpotifyCatalogError.invalidResponse }
        if response.statusCode == 404, emptyOnNotFound { return Data() }
        if response.statusCode == 429 { throw SpotifyCatalogError.limited }
        guard (200..<300).contains(response.statusCode) else { throw SpotifyCatalogError.unavailable }
        guard data.count <= 2 * 1024 * 1024 else { throw SpotifyCatalogError.invalidResponse }
        return data
    }
}
