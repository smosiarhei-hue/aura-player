// Path: Aurora/VKMusic/VKMusicService.swift

import Foundation

actor VKMusicService {
    private struct TrackCacheEntry: Sendable {
        let expiresAt: Date
        let tracks: [VKTrackDTO]
    }

    private struct PlaylistCacheEntry: Sendable {
        let expiresAt: Date
        let playlists: [VKPlaylistDTO]
    }

    private let tokenStore: VKTokenStore
    private let session: URLSession
    private let apiVersion: String
    private let cacheTTL: TimeInterval
    private var trackCache: [String: TrackCacheEntry] = [:]
    private var playlistCache: [String: PlaylistCacheEntry] = [:]
    private var lastRequestAt: Date = .distantPast

    init(
        tokenStore: VKTokenStore,
        session: URLSession = .shared,
        apiVersion: String = "5.131",
        cacheTTL: TimeInterval = 600
    ) {
        self.tokenStore = tokenStore
        self.session = session
        self.apiVersion = apiVersion
        self.cacheTTL = cacheTTL
    }

    func search(query: String, count: Int = 50, offset: Int = 0) async throws -> [VKTrackDTO] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let key = "search|\(clean.lowercased())|\(count)|\(offset)"
        if let cached = cachedTracks(for: key) { return cached }
        let response: VKListResponse<VKTrackDTO> = try await request(
            method: "audio.search",
            parameters: [
                "q": clean,
                "count": String(max(1, min(300, count))),
                "offset": String(max(0, offset)),
                "sort": "0",
                "autocomplete": "1"
            ]
        )
        cache(response.items, for: key)
        return response.items
    }

    func popular(count: Int = 100, offset: Int = 0) async throws -> [VKTrackDTO] {
        let key = "popular|\(count)|\(offset)"
        if let cached = cachedTracks(for: key) { return cached }
        let response: VKListResponse<VKTrackDTO> = try await request(
            method: "audio.getPopular",
            parameters: [
                "count": String(max(1, min(300, count))),
                "offset": String(max(0, offset))
            ]
        )
        cache(response.items, for: key)
        return response.items
    }

    func userTracks(ownerID: Int? = nil, count: Int = 100, offset: Int = 0) async throws -> [VKTrackDTO] {
        let token = try await validToken()
        let owner = ownerID ?? token.userID
        let key = "user|\(owner)|\(count)|\(offset)"
        if let cached = cachedTracks(for: key) { return cached }
        let response: VKListResponse<VKTrackDTO> = try await request(
            method: "audio.get",
            parameters: [
                "owner_id": String(owner),
                "count": String(max(1, min(300, count))),
                "offset": String(max(0, offset))
            ]
        )
        cache(response.items, for: key)
        return response.items
    }

    func playlists(ownerID: Int? = nil, count: Int = 50, offset: Int = 0) async throws -> [VKPlaylistDTO] {
        let token = try await validToken()
        let owner = ownerID ?? token.userID
        let key = "playlists|\(owner)|\(count)|\(offset)"
        if let cached = playlistCache[key], cached.expiresAt > Date() { return cached.playlists }
        let response: VKListResponse<VKPlaylistDTO> = try await request(
            method: "audio.getPlaylists",
            parameters: [
                "owner_id": String(owner),
                "count": String(max(1, min(100, count))),
                "offset": String(max(0, offset))
            ]
        )
        playlistCache[key] = PlaylistCacheEntry(
            expiresAt: Date().addingTimeInterval(cacheTTL),
            playlists: response.items
        )
        return response.items
    }

    func playlistTracks(_ playlist: VKPlaylistDTO, count: Int = 100, offset: Int = 0) async throws -> [VKTrackDTO] {
        var parameters = [
            "owner_id": String(playlist.ownerID),
            "album_id": String(playlist.id),
            "count": String(max(1, min(300, count))),
            "offset": String(max(0, offset))
        ]
        if let accessKey = playlist.accessKey, !accessKey.isEmpty {
            parameters["access_key"] = accessKey
        }
        let key = "playlist|\(playlist.ownerID)|\(playlist.id)|\(count)|\(offset)"
        if let cached = cachedTracks(for: key) { return cached }
        let response: VKListResponse<VKTrackDTO> = try await request(method: "audio.get", parameters: parameters)
        cache(response.items, for: key)
        return response.items
    }

    func refreshedTrack(_ track: VKTrackDTO) async throws -> VKTrackDTO {
        var identifier = track.compoundID
        if let accessKey = track.accessKey, !accessKey.isEmpty {
            identifier += "_\(accessKey)"
        }
        let response: [VKTrackDTO] = try await request(
            method: "audio.getById",
            parameters: ["audios": identifier]
        )
        guard let refreshed = response.first else { throw VKMusicError.unavailable }
        return refreshed
    }

    func clearMemoryCache() {
        trackCache.removeAll(keepingCapacity: false)
        playlistCache.removeAll(keepingCapacity: false)
    }

    private func request<Payload: Decodable & Sendable>(
        method: String,
        parameters: [String: String],
        retry: Int = 0
    ) async throws -> Payload {
        let token = try await validToken()
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 0.36 {
            try await Task.sleep(for: .seconds(0.36 - elapsed))
        }
        try Task.checkCancellation()

        guard let url = URL(string: "https://api.vk.com/method/\(method)") else {
            throw VKMusicError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")

        var body = parameters
        body["access_token"] = token.value
        body["v"] = apiVersion
        body["lang"] = "ru"
        body["https"] = "1"
        body["extended"] = "1"
        request.httpBody = Self.formEncoded(body).data(using: .utf8)
        lastRequestAt = Date()

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw VKMusicError.invalidResponse
        }
        let envelope = try JSONDecoder().decode(VKEnvelope<Payload>.self, from: data)
        if let payload = envelope.response { return payload }
        guard let error = envelope.error else { throw VKMusicError.invalidResponse }

        switch error.errorCode {
        case 5:
            try? await tokenStore.delete()
            throw VKMusicError.tokenExpired
        case 15, 201:
            throw VKMusicError.accessDenied
        case 6:
            guard retry < 2 else { throw VKMusicError.rateLimited }
            try await Task.sleep(for: .milliseconds(450 * (retry + 1)))
            return try await request(method: method, parameters: parameters, retry: retry + 1)
        default:
            throw VKMusicError.api(code: error.errorCode, message: error.errorMessage)
        }
    }

    private func validToken() async throws -> VKAccessToken {
        guard let token = try await tokenStore.load() else { throw VKMusicError.unauthorized }
        guard !token.isExpired else {
            try? await tokenStore.delete()
            throw VKMusicError.tokenExpired
        }
        return token
    }

    private func cachedTracks(for key: String) -> [VKTrackDTO]? {
        guard let entry = trackCache[key], entry.expiresAt > Date() else {
            trackCache[key] = nil
            return nil
        }
        return entry.tracks
    }

    private func cache(_ tracks: [VKTrackDTO], for key: String) {
        trackCache[key] = TrackCacheEntry(
            expiresAt: Date().addingTimeInterval(cacheTTL),
            tracks: tracks
        )
    }

    nonisolated private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(encode(key))=\(encode(value))"
            }
            .joined(separator: "&")
    }

    nonisolated private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=/?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
