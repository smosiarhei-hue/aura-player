import Foundation
import Observation

// MARK: - Synchronized Lyrics Service (LRCLIB → LRC → cache → static fallback)

@Observable
@MainActor
final class LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics] = [:]

    private struct TrackDetail: Codable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Hybrid parallel priority:
    /// 1. Synchronized LRC (Yandex or LRCLIB) -> dynamic karaoke display
    /// 2. Authoritative full text (Yandex Music official)
    /// 3. LRCLIB plain text
    /// 4. Embedded static lyrics
    func fetchLyrics(for track: Track) async throws -> Lyrics {
        let key = cacheKey(for: track)
        if let cached = cache[key] {
            return cached
        }

        // Fetch both sources concurrently for optimal speed and reliability
        async let yandexTask = fetchYandexLyrics(for: track)
        async let lrcTask = fetchLRCLib(for: track)

        let yandexLyrics = await yandexTask
        let lrcLyrics = await lrcTask

        // 1. If Yandex has synchronized lyrics, prioritize it
        if let yandexLyrics, yandexLyrics.isSynchronized {
            cache[key] = yandexLyrics
            return yandexLyrics
        }

        // 2. If LRCLIB has synchronized lyrics, prioritize it for dynamic karaoke animation
        if let lrcLyrics, lrcLyrics.isSynchronized {
            cache[key] = lrcLyrics
            return lrcLyrics
        }

        // 3. Official Yandex full text lyrics (authoritative and complete)
        if let yandexLyrics, !yandexLyrics.lines.isEmpty {
            cache[key] = yandexLyrics
            return yandexLyrics
        }

        // 4. LRCLIB plain lyrics
        if let lrcLyrics, !lrcLyrics.lines.isEmpty {
            cache[key] = lrcLyrics
            return lrcLyrics
        }

        // 5. Embedded ID3 static lyrics
        if let staticText = track.lyricsText, !staticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lyrics = staticLyrics(from: staticText, track: track)
            cache[key] = lyrics
            return lyrics
        }

        throw URLError(.resourceUnavailable)
    }

    private func fetchYandexLyrics(for track: Track) async -> Lyrics? {
        var ymId = PlayerCore.yandexTrackID(from: track)
        if ymId.isEmpty {
            ymId = await searchYandexTrackId(title: track.title, artist: track.artist) ?? ""
        }
        guard !ymId.isEmpty else { return nil }

        let cleanId = ymId.contains(":") ? (ymId.components(separatedBy: ":").last ?? ymId) : ymId
        guard let url = URL(string: YandexMusicService.apiBase + "/tracks/\(cleanId)/supplement") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let token = YandexMusicService.shared.token.isEmpty ? YandexMusicService.defaultToken : YandexMusicService.shared.token
        request.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        request.setValue("YandexMusic/2024.1", forHTTPHeaderField: "User-Agent")
        request.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        struct YMSupplementResponse: Decodable {
            struct Result: Decodable {
                struct LyricsData: Decodable {
                    let id: Int?
                    let lyrics: String?
                    let fullLyrics: String?
                    let hasRights: Bool?
                    let syncType: String?
                    let lrcLyrics: String?
                    let lrc: String?
                }
                let lyrics: LyricsData?
            }
            let result: Result?
        }

        guard let decoded = try? JSONDecoder().decode(YMSupplementResponse.self, from: data),
              let lyricsData = decoded.result?.lyrics else {
            return nil
        }

        // 1. Check for synchronized LRC lyrics
        if let lrcText = lyricsData.lrcLyrics ?? lyricsData.lrc, !lrcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = LRCParser.parse(lrcText)
            if !parsed.lines.isEmpty {
                return Lyrics(title: track.title, artist: track.artist, lines: parsed.lines, isSyllable: parsed.isSyllable)
            }
        }

        // 2. Check for full text lyrics
        if let rawText = lyricsData.fullLyrics ?? lyricsData.lyrics, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return staticLyrics(from: rawText, track: track)
        }

        return nil
    }

    private func searchYandexTrackId(title: String, artist: String) async -> String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }

        let query = (cleanArtist.isEmpty || cleanArtist == "Неизвестный исполнитель")
            ? cleanTitle
            : "\(cleanArtist) \(cleanTitle)"

        let results = await YandexMusicService.shared.searchAll(query: query)
        if let first = results.tracks.first, !first.id.isEmpty {
            return first.id
        }

        // Secondary fallback if combined query yielded 0 tracks
        if !cleanArtist.isEmpty && cleanArtist != "Неизвестный исполнитель" {
            let fallbackResults = await YandexMusicService.shared.searchAll(query: cleanTitle)
            if let first = fallbackResults.tracks.first, !first.id.isEmpty {
                return first.id
            }
        }

        return nil
    }

    private func fetchLRCLib(for track: Track) async -> Lyrics? {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { return nil }

        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(Int(track.duration))"))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("SonivoPlayer/1.0 (https://github.com/smosiarhei-hue/aura-player)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let detail = try? JSONDecoder().decode(TrackDetail.self, from: data) else {
            return nil
        }

        if let synced = detail.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = LRCParser.parse(synced)
            if !parsed.lines.isEmpty {
                return Lyrics(title: detail.trackName ?? track.title,
                              artist: detail.artistName ?? track.artist,
                              lines: parsed.lines,
                              isSyllable: parsed.isSyllable)
            }
        }

        if let plain = detail.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return staticLyrics(from: plain, track: track)
        }

        return nil
    }

    private func staticLyrics(from text: String, track: Track) -> Lyrics {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricsLine(text: $0, startTime: 0, endTime: nil, words: nil) }
        return Lyrics(title: track.title, artist: track.artist, lines: lines, isSyllable: false)
    }

    private func cacheKey(for track: Track) -> String {
        "\(track.title.lowercased())|\(track.artist.lowercased())"
    }
}
