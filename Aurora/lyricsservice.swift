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

        // Fetch sources concurrently for optimal speed, reliability, and coverage
        async let yandexTask = fetchYandexLyrics(for: track)
        async let lrcTask = fetchLRCLib(for: track)
        async let geniusTask = fetchGeniusLyrics(for: track)

        let yandexLyrics = await yandexTask
        let lrcLyrics = await lrcTask
        let geniusLyrics = await geniusTask

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

        // 4. Genius full text lyrics (instant 100% day-one coverage for new releases)
        if let geniusLyrics, !geniusLyrics.lines.isEmpty {
            cache[key] = geniusLyrics
            return geniusLyrics
        }

        // 5. LRCLIB plain lyrics
        if let lrcLyrics, !lrcLyrics.lines.isEmpty {
            cache[key] = lrcLyrics
            return lrcLyrics
        }

        // 6. Embedded ID3 static lyrics
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

    private func fetchGeniusLyrics(for track: Track) async -> Lyrics? {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let query = (artist.isEmpty || artist == "Неизвестный исполнитель")
            ? title
            : "\(artist) \(title)"

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://genius.com/api/search/multi?q=\(encoded)") else {
            return nil
        }

        var searchReq = URLRequest(url: searchURL)
        searchReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        searchReq.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (searchData, searchResp) = try? await URLSession.shared.data(for: searchReq),
              (searchResp as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        struct GeniusSearchResponse: Decodable {
            struct Response: Decodable {
                struct Section: Decodable {
                    let type: String?
                    struct Hit: Decodable {
                        struct Result: Decodable {
                            let path: String?
                            let title: String?
                        }
                        let result: Result?
                    }
                    let hits: [Hit]?
                }
                let sections: [Section]?
            }
            let response: Response?
        }

        guard let decoded = try? JSONDecoder().decode(GeniusSearchResponse.self, from: searchData),
              let sections = decoded.response?.sections else {
            return nil
        }

        var songPath: String?
        for section in sections where section.type == "song" || section.type == "top_hit" {
            if let firstHit = section.hits?.first?.result, let path = firstHit.path, !path.isEmpty {
                songPath = path
                break
            }
        }

        guard let path = songPath, let pageURL = URL(string: "https://genius.com\(path)") else {
            return nil
        }

        var pageReq = URLRequest(url: pageURL)
        pageReq.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        guard let (pageData, pageResp) = try? await URLSession.shared.data(for: pageReq),
              (pageResp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: pageData, encoding: .utf8) else {
            return nil
        }

        let extracted = parseGeniusHTML(html)
        guard !extracted.isEmpty else { return nil }

        return staticLyrics(from: extracted, track: track)
    }

    private func parseGeniusHTML(_ html: String) -> String {
        let pattern = #"<div[^>]*data-lyrics-container="true"[^>]*>(.*?)</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return ""
        }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return "" }

        var collectedParts: [String] = []
        for match in matches {
            if match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                let part = nsHTML.substring(with: range)
                collectedParts.append(part)
            }
        }

        var raw = collectedParts.joined(separator: "\n")
        raw = raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        raw = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        raw = raw.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#x27;", with: "'")

        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
