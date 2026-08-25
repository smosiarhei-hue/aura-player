import Foundation

// MARK: - Jamendo API Service

enum JamendoService {
    // Register at https://developer.jamendo.com to get your own client_id
    // This is a demo client_id — replace with your own for production
    static let clientId = "b4df5ac3"
    static let baseUrl = "https://api.jamendo.com/v3.0"
    static let streamUrl = "https://streaming.jamendo.com/v3.0/tracks"

    // MARK: - Models

    struct JamendoTrack: Identifiable, Codable {
        let id: String
        let name: String
        let artist_name: String
        let album_name: String
        let duration: Double
        let image: String?
        let audio: String  // mp3 stream URL
        let shareurl: String?
        let musicinfo: JamendoMusicInfo?

        var artist: String { artist_name }
        var album: String { album_name }
    }

    struct JamendoMusicInfo: Codable {
        let tags: Tags?
        struct Tags: Codable {
            genres: [String]?
            let instrumentations: [String]?
            let moods: [String]?
        }
    }

    struct JamendoResponse: Codable {
        let results: [JamendoTrack]
        let headers: JamendoHeaders?
    }

    struct JamendoHeaders: Codable {
        let results_count: Int
        let pages: Int?
        let current_page: Int?
    }

    // MARK: - Search

    static func search(query: String, limit: Int = 30, offset: Int = 0) async throws -> [JamendoTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "order", value: "popularity_total")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let resp = try JSONDecoder().decode(JamendoResponse.self, from: data)
        return resp.results
    }

    // MARK: - Popular / trending

    static func popular(limit: Int = 30, offset: Int = 0) async throws -> [JamendoTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "order", value: "popularity_total")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let resp = try JSONDecoder().decode(JamendoResponse.self, from: data)
        return resp.results
    }

    // MARK: - Stream URL

    static func streamURL(trackId: String) -> URL {
        var components = URLComponents(string: streamUrl)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "track_id", value: trackId)
        ]
        return components.url!
    }

    // MARK: - Genres

    struct Genre: Identifiable, Codable {
        let id: String
        let name: String
        var displayName: String {
            switch name {
            case "pop": return "Поп"
            case "rock": return "Рок"
            case "electronic": return "Электроника"
            case "hiphop": return "Хип-хоп"
            case "jazz": return "Джаз"
            case "classical": return "Классика"
            case "latin": return "Латин"
            case "ambient": return "Эмбиент"
            case "folk": return "Фолк"
            case "rnb": return "R&B"
            case "metal": return "Метал"
            case "blues": return "Блюз"
            case "country": return "Кантри"
            case "reggae": return "Регги"
            case "soul": return "Соул"
            case "funk": return "Фанк"
            case "worldmusic": return "Мир"
            default: return name
            }
        }
        let image: String?
    }

    struct GenreListResponse: Codable {
        let results: [Genre]
    }

    static func genres() async throws -> [Genre] {
        var components = URLComponents(string: "\(baseUrl)/genres")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let resp = try JSONDecoder().decode(GenreListResponse.self, from: data)
        return resp.results
    }

    // MARK: - Tracks by genre

    static func tracksByGenre(_ genreId: String, limit: Int = 30, offset: Int = 0) async throws -> [JamendoTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "tags", value: genreId),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "order", value: "popularity_total")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let resp = try JSONDecoder().decode(JamendoResponse.self, from: data)
        return resp.results
    }
}
