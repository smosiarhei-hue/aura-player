import Foundation

// MARK: - Jamendo API Client (Full Online Music Streaming)

enum JamendoService {
    static let clientId = "85f16e77"
    static let clientSecret = "6ae185c2eefc36de1faaed206010d051"
    static let baseUrl = "https://api.jamendo.com/v3.0"

    struct JTrack: Identifiable, Codable, Equatable {
        let id: String
        let name: String
        let artist_name: String
        let album_name: String
        let duration: Double
        let image: String?
        let audio: String              // full streaming URL
        let audiodownload: String?     // download URL
        let releasedate: String?
        let license_cc: String?
        let musicinfo: JMusicInfo?

        var title: String { name.isEmpty ? "Без названия" : name }
        var artist: String { artist_name.isEmpty ? "Неизвестный исполнитель" : artist_name }
        var album: String { album_name.isEmpty ? "Сингл" : album_name }
        var coverUrl: String? { image }
        var streamUrl: String { audio }

        static func == (lhs: JTrack, rhs: JTrack) -> Bool { lhs.id == rhs.id }
    }

    struct JMusicInfo: Codable, Equatable {
        let tags: JTags?
        struct JTags: Codable, Equatable {
            let genres: [String]?
            let instrumentations: [String]?
            let moods: [String]?
        }
    }

    struct JResponse: Codable {
        let results: [JTrack]
    }

    // MARK: - Home: Trending & Featured Tracks

    static func trending(limit: Int = 30) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "order", value: "popularity_week"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "audioformat", value: "mp32")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - New: Fresh Releases

    static func newReleases(limit: Int = 30) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "order", value: "releasedate_desc"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "audioformat", value: "mp32")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - Radio Stations & Genres

    struct RadioStation: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let genreTag: String
        let coverGradient: [String]
        let iconName: String
    }

    static let stations: [RadioStation] = [
        RadioStation(id: "pop", title: "Pop Hits", subtitle: "Главные поп-хиты онлайн", genreTag: "pop", coverGradient: ["#EC4899", "#8B5CF6"], iconName: "sparkles"),
        RadioStation(id: "electronic", title: "Dance & Club", subtitle: "Энергичный электронный бит", genreTag: "electronic", coverGradient: ["#3B82F6", "#06B6D4"], iconName: "bolt.fill"),
        RadioStation(id: "rock", title: "Rock Classics", subtitle: "Драйв, гитары и рок-н-ролл", genreTag: "rock", coverGradient: ["#EF4444", "#F59E0B"], iconName: "guitars.fill"),
        RadioStation(id: "hiphop", title: "Hip-Hop & Trap", subtitle: "Свежий бит и флоу", genreTag: "hiphop", coverGradient: ["#F97316", "#DC2626"], iconName: "waveform.path.ecg"),
        RadioStation(id: "chillout", title: "Lo-Fi & Chill", subtitle: "Спокойная музыка для работы и отдыха", genreTag: "chillout", coverGradient: ["#10B981", "#3B82F6"], iconName: "cup.and.saucer.fill"),
        RadioStation(id: "ambient", title: "Deep Ambient", subtitle: "Глубокая медитация и фокус", genreTag: "ambient", coverGradient: ["#6366F1", "#A855F7"], iconName: "moon.stars.fill"),
        RadioStation(id: "jazz", title: "Smooth Jazz", subtitle: "Тёплый вечерний джаз", genreTag: "jazz", coverGradient: ["#D97706", "#78350F"], iconName: "music.quarternote.3"),
        RadioStation(id: "classical", title: "Classical Masterpieces", subtitle: "Классические симфонии", genreTag: "classical", coverGradient: ["#475569", "#1E293B"], iconName: "pianokeys.inverse")
    ]

    static func tracksForStation(_ station: RadioStation, limit: Int = 30) async throws -> [JTrack] {
        try await tracksByGenre(station.genreTag, limit: limit)
    }

    static func tracksByGenre(_ genre: String, limit: Int = 30) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "tags", value: genre),
            URLQueryItem(name: "order", value: "popularity_total"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "audioformat", value: "mp32")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - Search

    static func search(query: String, limit: Int = 40) async throws -> [JTrack] {
        var components = URLComponents(string: "\(baseUrl)/tracks/")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "audioformat", value: "mp32")
        ]
        return try await fetchTracks(components.url!)
    }

    // MARK: - Convert Jamendo track to App Track Model

    static func convertToTrack(_ item: JTrack) -> Track {
        let seed = Int(String(item.id.prefix(6))) ?? 42
        return Track(
            id: UUID(),
            fileName: "online_\(item.id).mp3",
            relativePath: "",
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            artworkSeed: seed,
            colorsHex: ["#2DD4BF", "#6366F1"],
            hasEmbeddedArtwork: false,
            isFavorite: false,
            addedAt: Date(),
            isStream: true,
            streamUrlString: item.streamUrl,
            coverURL: item.coverUrl
        )
    }

    // MARK: - Helper

    private static func fetchTracks(_ url: URL) async throws -> [JTrack] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(JResponse.self, from: data)
        return decoded.results
    }
}
