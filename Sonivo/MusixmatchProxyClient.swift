import Foundation

/// Client for a first-party proxy that keeps the Musixmatch partner key off-device.
/// Expected endpoints:
/// GET /search?artist=...&title=... -> TrackInfo JSON
/// GET /subtitle/{trackId}          -> raw LRC text
/// GET /richsync/{trackId}          -> Musixmatch RichSync JSON array
struct MusixmatchProxyClient {
    let baseURL: URL

    func fetchLyrics(for track: Track) async -> Lyrics? {
        guard let match = try? await search(artist: track.artist, title: track.title) else {
            return nil
        }

        let resolvedTitle = match.name.isEmpty ? track.title : match.name
        let resolvedArtist = match.artist.isEmpty ? track.artist : match.artist

        if match.hasRichsync != 0,
           let richSync = try? await richsync(
                trackID: match.trackID,
                title: resolvedTitle,
                artist: resolvedArtist
           ), !richSync.lines.isEmpty {
            return richSync
        }

        if let synced = try? await subtitle(
            trackID: match.trackID,
            title: resolvedTitle,
            artist: resolvedArtist
        ), !synced.lines.isEmpty {
            return synced
        }

        // Some proxy backends omit has_richsync even when the endpoint is available.
        if match.hasRichsync == 0,
           let richSync = try? await richsync(
                trackID: match.trackID,
                title: resolvedTitle,
                artist: resolvedArtist
           ), !richSync.lines.isEmpty {
            return richSync
        }

        if let plain = try? await plainLyrics(
            trackID: match.trackID,
            title: resolvedTitle,
            artist: resolvedArtist
        ), !plain.lines.isEmpty {
            return plain
        }

        return nil
    }

    // MARK: - Full read-only proxy stack

    func matcherLyrics(artist: String, title: String) async throws -> Data {
        try await endpoint("matcher/lyrics", queryItems: [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title)
        ])
    }

    func matcherSubtitle(
        artist: String,
        title: String,
        format: String = "lrc"
    ) async throws -> Data {
        try await endpoint("matcher/subtitle", queryItems: [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "format", value: format)
        ])
    }

    func trackSearch(
        query: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        lyrics: String? = nil,
        page: Int = 1,
        pageSize: Int = 10
    ) async throws -> Data {
        try await endpoint("track/search", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "lyrics", value: lyrics),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ])
    }

    func trackMetadata(
        trackID: Int? = nil,
        commonTrackID: Int? = nil,
        isrc: String? = nil,
        spotifyID: String? = nil
    ) async throws -> Data {
        try await endpoint("track/get", queryItems: [
            URLQueryItem(name: "track_id", value: trackID.map { String($0) }),
            URLQueryItem(name: "commontrack_id", value: commonTrackID.map { String($0) }),
            URLQueryItem(name: "isrc", value: isrc),
            URLQueryItem(name: "spotify_id", value: spotifyID)
        ])
    }

    func trackLyrics(trackID: Int) async throws -> Data {
        try await endpoint("lyrics/\(trackID)")
    }

    func trackLyricsTranslation(trackID: Int, language: String) async throws -> Data {
        try await endpoint("lyrics/\(trackID)/translation", queryItems: [
            URLQueryItem(name: "language", value: language)
        ])
    }

    func trackSnippet(trackID: Int) async throws -> Data {
        try await endpoint("snippet/\(trackID)")
    }

    func trackSubtitleTranslation(
        trackID: Int,
        language: String,
        format: String = "lrc"
    ) async throws -> Data {
        try await endpoint("subtitle/\(trackID)/translation", queryItems: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: format)
        ])
    }

    func chartTracks(
        country: String = "us",
        page: Int = 1,
        pageSize: Int = 10
    ) async throws -> Data {
        try await endpoint("chart/tracks", queryItems: [
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ])
    }

    func artistSearch(
        artist: String,
        page: Int = 1,
        pageSize: Int = 10
    ) async throws -> Data {
        try await endpoint("artist/search", queryItems: [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize))
        ])
    }

    func artistMetadata(artistID: Int) async throws -> Data {
        try await endpoint("artist/\(artistID)")
    }

    func albumMetadata(albumID: Int) async throws -> Data {
        try await endpoint("album/\(albumID)")
    }

    private func search(artist: String, title: String) async throws -> TrackInfo {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "title", value: title)
        ]
        guard let url = components.url else { throw MusixmatchProxyError.invalidURL }
        let data = try await request(url)
        return try JSONDecoder().decode(TrackInfo.self, from: data)
    }

    private func subtitle(trackID: Int, title: String, artist: String) async throws -> Lyrics {
        let url = baseURL
            .appendingPathComponent("subtitle")
            .appendingPathComponent(String(trackID))
        let data = try await request(url)
        guard let lrc = String(data: data, encoding: .utf8), !lrc.isEmpty else {
            return .empty
        }

        let parsed = LRCParser.parse(lrc, sourceName: "Musixmatch Proxy")
        return Lyrics(
            title: title,
            artist: artist,
            lines: parsed.lines,
            isSyllable: parsed.isSyllable,
            offset: parsed.offset,
            sourceName: "Musixmatch Proxy"
        )
    }

    private func richsync(trackID: Int, title: String, artist: String) async throws -> Lyrics {
        let url = baseURL
            .appendingPathComponent("richsync")
            .appendingPathComponent(String(trackID))
        let data = try await request(url)
        let lines = try RichSyncParser.parse(data: data)
        return Lyrics(
            title: title,
            artist: artist,
            lines: lines,
            isSyllable: lines.contains { $0.hasRealWordTimings },
            sourceName: "Musixmatch Proxy RichSync"
        )
    }

    private func plainLyrics(trackID: Int, title: String, artist: String) async throws -> Lyrics {
        let data = try await endpoint("lyrics/\(trackID)")
        let payload = try JSONDecoder().decode(ProxyLyricsPayload.self, from: data)
        let lines = (payload.lyrics?.body ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*******") }
            .map { LyricsLine(text: $0, startTime: 0, endTime: nil) }
        return Lyrics(
            title: title,
            artist: artist,
            lines: lines,
            isSyllable: false,
            sourceName: "Musixmatch Proxy"
        )
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("Sonivo/1.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw MusixmatchProxyError.httpFailure
        }
        guard !data.isEmpty else { throw MusixmatchProxyError.emptyResponse }
        return data
    }

    private func endpoint(
        _ path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems.filter { item in
            guard let value = item.value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let url = components.url else { throw MusixmatchProxyError.invalidURL }
        return try await request(url)
    }
}

private enum MusixmatchProxyError: Error {
    case invalidURL
    case httpFailure
    case emptyResponse
}

private struct TrackInfo: Decodable {
    let trackID: Int
    let name: String
    let artist: String
    let hasRichsync: Int

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case name
        case artist
        case hasRichsync = "has_richsync"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(Int.self, forKey: .trackID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        if let value = try? container.decode(Int.self, forKey: .hasRichsync) {
            hasRichsync = value
        } else if let value = try? container.decode(Bool.self, forKey: .hasRichsync) {
            hasRichsync = value ? 1 : 0
        } else {
            hasRichsync = 0
        }
    }
}

private struct ProxyLyricsPayload: Decodable {
    struct Item: Decodable {
        let body: String

        enum CodingKeys: String, CodingKey {
            case body = "lyrics_body"
        }
    }

    let lyrics: Item?
}
