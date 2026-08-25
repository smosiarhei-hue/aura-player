import Foundation

// MARK: - Deezer API (search, 30s preview, album art — no key needed)

enum DeezerService {
    static let baseUrl = "https://api.deezer.com"
    
    struct DzTrack: Identifiable, Codable {
        let id: Int
        let title: String
        let title_short: String?
        let artist: DzArtist
        let album: DzAlbum
        let duration: Int
        let preview: String
        
        var artistName: String { artist.name }
        var albumName: String { album.title }
        var coverUrl: String { album.cover_medium }
        var coverBigUrl: String { album.cover_big }
    }
    
    struct DzArtist: Codable { let id: Int; let name: String; let picture_medium: String? }
    struct DzAlbum: Codable {
        let id: Int; let title: String
        let cover_small: String; let cover_medium: String; let cover_big: String
    }
    
    struct DzResponse<T: Codable>: Codable { let data: [T]; let total: Int?; let next: String? }
    
    static func search(query: String, limit: Int = 30, offset: Int = 0) async throws -> [DzTrack] {
        var components = URLComponents(string: "\(baseUrl)/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let resp = try JSONDecoder().decode(DzResponse<DzTrack>.self, from: data)
        return resp.data
    }
    
    static func charts(limit: Int = 30) async throws -> [DzTrack] {
        let url = URL(string: "\(baseUrl)/chart/0/tracks?limit=\(limit)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(DzResponse<DzTrack>.self, from: data)
        return resp.data
    }
    
    static func genreChart(_ genreId: Int, limit: Int = 30) async throws -> [DzTrack] {
        let url = URL(string: "\(baseUrl)/chart/\(genreId)/tracks?limit=\(limit)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(DzResponse<DzTrack>.self, from: data)
        return resp.data
    }
    
    struct DzGenre: Identifiable, Codable {
        let id: Int; let name: String; let picture: String?
    }
    struct DzGenreResponse: Codable { let data: [DzGenre] }
    
    static func genres() async throws -> [DzGenre] {
        let url = URL(string: "\(baseUrl)/genre")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let resp = try JSONDecoder().decode(DzGenreResponse.self, from: data)
        return resp.data
    }
    
    static func previewURL(_ preview: String) -> URL? {
        URL(string: preview)
    }
}
