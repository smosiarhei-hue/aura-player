import Foundation
import Observation

extension Notification.Name {
    static let didUpdateCustomLyrics = Notification.Name("sonivo.didUpdateCustomLyrics")
}

// MARK: - Synchronized Lyrics Service (Custom -> LRCLIB -> LRC -> cache -> static fallback)

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
    /// 0. User custom lyrics (plain or dynamic LRC)
    /// 1. Synchronized LRC (Yandex or LRCLIB) -> dynamic karaoke display
    /// 2. Authoritative full text (Yandex Music official)
    /// 3. LRCLIB plain text
    /// 4. Embedded static lyrics
    func fetchLyrics(for track: Track) async throws -> Lyrics {
        let key = cacheKey(for: track)

        // 0. User-provided custom lyrics have top priority
        if let custom = getCustomLyrics(for: track) {
            cache[key] = custom
            return custom
        }

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
            let parsed = LRCParser.parse(lrcText, sourceName: "Яндекс Музыка")
            if !parsed.lines.isEmpty {
                return Lyrics(title: track.title, artist: track.artist, lines: parsed.lines, isSyllable: parsed.isSyllable, sourceName: "Яндекс Музыка")
            }
        }

        // 2. Check for full text lyrics
        if let rawText = lyricsData.fullLyrics ?? lyricsData.lyrics, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return staticLyrics(from: rawText, track: track, sourceName: "Яндекс Музыка")
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

        // 1. Try exact match with duration
        if let detail = await requestLRCLibGet(artist: artist, title: title, duration: track.duration > 0 ? Int(track.duration) : nil) {
            if let lyrics = convertLRCLibDetail(detail, track: track) {
                return lyrics
            }
        }

        // 2. Try exact match without duration (in case track length differs slightly between mastering releases)
        if track.duration > 0,
           let detail = await requestLRCLibGet(artist: artist, title: title, duration: nil) {
            if let lyrics = convertLRCLibDetail(detail, track: track) {
                return lyrics
            }
        }

        // 3. Fallback: Search endpoint (deals with subtle title differences like "Song (feat. X)", "Remastered", etc.)
        let cleanTitle = title
            .replacingOccurrences(of: #"\s*\(.*?\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[.*?\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let detail = await searchLRCLibFirst(title: cleanTitle.isEmpty ? title : cleanTitle, artist: artist) {
            if let lyrics = convertLRCLibDetail(detail, track: track) {
                return lyrics
            }
        }

        return nil
    }

    private func requestLRCLibGet(artist: String, title: String, duration: Int?) async -> TrackDetail? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title)
        ]
        if let duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(duration)"))
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
        return detail
    }

    private func searchLRCLibFirst(title: String, artist: String) async -> TrackDetail? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("SonivoPlayer/1.0 (https://github.com/smosiarhei-hue/aura-player)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode([TrackDetail].self, from: data) else {
            return nil
        }

        // Prioritize results that have synchronized lyrics
        if let syncedItem = list.first(where: { ($0.syncedLyrics?.count ?? 0) > 20 }) {
            return syncedItem
        }
        return list.first
    }

    private func convertLRCLibDetail(_ detail: TrackDetail, track: Track) -> Lyrics? {
        if let synced = detail.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = LRCParser.parse(synced, sourceName: "LRCLIB")
            if !parsed.lines.isEmpty {
                return Lyrics(
                    title: detail.trackName ?? track.title,
                    artist: detail.artistName ?? track.artist,
                    lines: parsed.lines,
                    isSyllable: parsed.isSyllable,
                    sourceName: "LRCLIB"
                )
            }
        }
        if let plain = detail.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return staticLyrics(from: plain, track: track, sourceName: "LRCLIB")
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

        return staticLyrics(from: extracted, track: track, sourceName: "Genius")
    }

    private func parseGeniusHTML(_ html: String) -> String {
        let marker = "data-lyrics-container=\"true\""
        var containers: [String] = []
        var searchStart = html.startIndex

        while let markerRange = html.range(of: marker, range: searchStart..<html.endIndex) {
            // Find opening tag '>'
            guard let tagEnd = html.range(of: ">", range: markerRange.upperBound..<html.endIndex) else {
                break
            }

            var depth = 1
            var cursor = tagEnd.upperBound
            let contentStart = cursor

            while cursor < html.endIndex && depth > 0 {
                let remaining = cursor..<html.endIndex
                let nextOpen = html.range(of: "<div", range: remaining)
                let nextClose = html.range(of: "</div>", range: remaining)

                guard let closeRange = nextClose else { break }

                if let openRange = nextOpen, openRange.lowerBound < closeRange.lowerBound {
                    depth += 1
                    cursor = openRange.upperBound
                } else {
                    depth -= 1
                    if depth == 0 {
                        let containerContent = String(html[contentStart..<closeRange.lowerBound])
                        containers.append(containerContent)
                        searchStart = closeRange.upperBound
                        break
                    }
                    cursor = closeRange.upperBound
                }
            }

            if depth > 0 {
                searchStart = tagEnd.upperBound
            }
        }

        guard !containers.isEmpty else { return "" }

        var raw = containers.joined(separator: "\n")
        // Strip data-exclude-from-selection blocks (header titles, ads, comments)
        raw = raw.replacingOccurrences(
            of: #"<div[^>]*data-exclude-from-selection="true"[^>]*>.*?</div>"#,
            with: "",
            options: .regularExpression
        )
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

    private func staticLyrics(from text: String, track: Track, sourceName: String = "Встроенный текст") -> Lyrics {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricsLine(text: $0, startTime: 0, endTime: nil, words: nil) }
        return Lyrics(title: track.title, artist: track.artist, lines: lines, isSyllable: false, sourceName: sourceName)
    }

    private func cacheKey(for track: Track) -> String {
        "\(track.title.lowercased())|\(track.artist.lowercased())"
    }

    // MARK: - Пользовательский текст (Обычный и Динамический LRC)

    func getCustomLyrics(for track: Track) -> Lyrics? {
        let key = "custom_lyrics_\(track.id.uuidString)"
        if let text = UserDefaults.standard.string(forKey: key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parseCustomLyrics(text, track: track)
        }

        let fallbackKey = "custom_lyrics_\(cacheKey(for: track))"
        if let fallbackText = UserDefaults.standard.string(forKey: fallbackKey), !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parseCustomLyrics(fallbackText, track: track)
        }

        return nil
    }

    func parseCustomLyrics(_ rawText: String, track: Track) -> Lyrics {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Проверяем, содержит ли текст таймкоды LRC формата [mm:ss.xx]
        if trimmed.contains("[") && trimmed.contains("]") {
            let parsed = LRCParser.parse(trimmed, sourceName: "Пользовательский (LRC)")
            if parsed.isSynchronized {
                return parsed
            }
        }

        // 2. Проверяем флаг динамического распределения по длительности
        let isDynamic = UserDefaults.standard.bool(forKey: "custom_lyrics_dynamic_\(track.id.uuidString)")
        if isDynamic {
            let rawLines = trimmed.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !rawLines.isEmpty else { return .empty }
            let totalDur = track.duration > 10 ? track.duration : 180.0
            let interval = max(1.8, (totalDur - 5.0) / Double(rawLines.count))
            var lines: [LyricsLine] = []
            for (idx, line) in rawLines.enumerated() {
                let start = Double(idx) * interval
                let end = start + interval
                lines.append(LyricsLine(text: line, startTime: start, endTime: end))
            }
            return Lyrics(title: track.title, artist: track.artist, lines: lines, isSyllable: false, sourceName: "Пользовательский (Синхронный)")
        }

        return staticLyrics(from: trimmed, track: track, sourceName: "Пользовательский текст")
    }

    func saveCustomLyrics(text: String, isDynamic: Bool, for track: Track) {
        let key = "custom_lyrics_\(track.id.uuidString)"
        let fallbackKey = "custom_lyrics_\(cacheKey(for: track))"
        let dynamicKey = "custom_lyrics_dynamic_\(track.id.uuidString)"

        UserDefaults.standard.set(text, forKey: key)
        UserDefaults.standard.set(text, forKey: fallbackKey)
        UserDefaults.standard.set(isDynamic, forKey: dynamicKey)

        let parsed = parseCustomLyrics(text, track: track)
        cache[cacheKey(for: track)] = parsed
        NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: track.id)
    }

    func removeCustomLyrics(for track: Track) {
        let key = "custom_lyrics_\(track.id.uuidString)"
        let fallbackKey = "custom_lyrics_\(cacheKey(for: track))"
        let dynamicKey = "custom_lyrics_dynamic_\(track.id.uuidString)"

        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        UserDefaults.standard.removeObject(forKey: dynamicKey)
        cache.removeValue(forKey: cacheKey(for: track))
        NotificationCenter.default.post(name: .didUpdateCustomLyrics, object: track.id)
    }
}
