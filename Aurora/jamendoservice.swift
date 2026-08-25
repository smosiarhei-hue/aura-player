import Foundation

// MARK: - Jamendo API (600K+ tracks, full streaming, free)

enum JamendoService {
    static let clientId = "85f16e77"
    static let baseUrl = "https://api.jamendo.com/v3.0"

    struct JTrack: Identifiable, Codable {
        let id: String
        let name: String
        let artist_name: String
        let album_name: String
        let duration: Double
        let image: String?
        let audio: String              // full track stream URL
        let musicinfo: JMusicInfo?

        var title: String { name }
        var artist: String { artist_name }
        var album: String { album_name }
        var coverUrl: String? { image }
        var streamUrl: String? { audio }
    }

    struct JMusicInfo: Codable {
        let tags: JTags?
        struct JTags: Codable {
            let genres: [String]?
            let instrumentations: [String]?
            let moods: [String]?
        }
    }

    struct JResponse: Codable {
        let results: [JTrack]
        let count: Int?
    }

    // MARK: - Search

    static func search(query: String, limit: Int = 30, offset: Int = 0) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "include", value: "musicinfo")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - Popular / Charts

    static func popular(limit: Int = 30, offset: Int = 0) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "order", value: "popularity_total"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "include", value: "musicinfo")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - By Genre

    static func tracksByGenre(_ genreId: String, limit: Int = 30) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "tags", value: genreId),
            URLQueryItem(name: "order", value: "popularity_total"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "musicinfo")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - Genres

    struct JGenre: Identifiable, Codable {
        let id: String
        let name: String
        var displayName: String {
            // Jamendo returns names like "Pop Rock" — keep as-is
            name
        }
    }

    struct JGenreResponse: Codable {
        let results: [JGenre]
    }

    static func genres() async throws -> [JGenre] {
        var components = URLComponents(string: "\(baseUrl)/genres/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let resp = try JSONDecoder().decode(JGenreResponse.self, from: data)
        return resp.results
    }

    // MARK: - Helpers

    private static func fetchTracks(_ url: URL) async throws -> [JTrack] {
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(JResponse.self, from: data)
        return resp.results
    }

    static func streamURL(_ audio: String) -> URL? {
        URL(string: audio)
    }
}