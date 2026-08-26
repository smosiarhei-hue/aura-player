import Foundation

// MARK: - Synchronized Lyrics Service (LRCLIB → LRC → cache → static fallback)

@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    private var cache: [String: Lyrics] = [:]

    private struct TrackDetail: Codable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Priority: LRCLIB synced → LRCLIB plain → embedded static text.
    func fetchLyrics(for track: Track) async throws -> Lyrics {
        let key = cacheKey(for: track)
        if let cached = cache[key] {
            return cached
        }

        if let remote = await fetchLRCLib(for: track) {
            cache[key] = remote
            return remote
        }

        if let staticText = track.lyricsText, !staticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lyrics = staticLyrics(from: staticText, track: track)
            cache[key] = lyrics
            return lyrics
        }

        throw URLError(.resourceUnavailable)
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
