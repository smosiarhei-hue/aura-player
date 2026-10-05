import Foundation

/// Official Musixmatch partner API client focused on time-synchronized lyrics.
struct MusixmatchClient {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.musixmatch.com/ws/1.1/")!

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func fetchLyrics(for track: Track) async -> Lyrics? {
        guard !apiKey.isEmpty,
              let match = try? await searchTrack(artist: track.artist, title: track.title) else {
            return nil
        }

        if let richSync = try? await getRichSyncLyrics(
            trackID: match.id,
            title: match.title ?? track.title,
            artist: match.artist ?? track.artist
        ), !richSync.lines.isEmpty {
            return richSync
        }

        if let synced = try? await getSyncedLyrics(
            trackID: match.id,
            title: match.title ?? track.title,
            artist: match.artist ?? track.artist
        ), !synced.lines.isEmpty {
            return synced
        }

        return nil
    }

    private struct TrackMatch {
        let id: Int
        let title: String?
        let artist: String?
    }

    private func searchTrack(artist: String, title: String) async throws -> TrackMatch? {
        let response: TrackSearchResponse = try await request(
            method: "track.search",
            queryItems: [
                URLQueryItem(name: "q_artist", value: artist),
                URLQueryItem(name: "q_track", value: title),
                URLQueryItem(name: "page_size", value: "5"),
                URLQueryItem(name: "s_track_rating", value: "desc")
            ]
        )

        let targetTitle = normalize(title)
        let targetArtist = normalize(artist)
        let tracks = response.message.body.trackList.map(\.track)

        let best = tracks.first { candidate in
            let candidateTitle = normalize(candidate.trackName ?? "")
            let candidateArtist = normalize(candidate.artistName ?? "")
            let titleMatches = candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle)
            let artistMatches = targetArtist.isEmpty ||
                candidateArtist.contains(targetArtist) ||
                targetArtist.contains(candidateArtist)
            return titleMatches && artistMatches
        } ?? tracks.first

        guard let best else { return nil }
        return TrackMatch(id: best.trackID, title: best.trackName, artist: best.artistName)
    }

    private func getSyncedLyrics(trackID: Int, title: String, artist: String) async throws -> Lyrics {
        let response: SubtitleResponse = try await request(
            method: "track.subtitle.get",
            queryItems: [
                URLQueryItem(name: "track_id", value: "\(trackID)"),
                URLQueryItem(name: "subtitle_format", value: "lrc")
            ]
        )
        guard let body = response.message.body.subtitle?.subtitleBody, !body.isEmpty else {
            return .empty
        }

        let parsed = LRCParser.parse(body, sourceName: "Musixmatch")
        return Lyrics(
            title: title,
            artist: artist,
            lines: parsed.lines,
            isSyllable: parsed.isSyllable,
            offset: parsed.offset,
            sourceName: "Musixmatch"
        )
    }

    private func getRichSyncLyrics(trackID: Int, title: String, artist: String) async throws -> Lyrics {
        let response: RichSyncResponse = try await request(
            method: "track.richsync.get",
            queryItems: [URLQueryItem(name: "track_id", value: "\(trackID)")]
        )
        guard let body = response.message.body.richsync?.richsyncBody, !body.isEmpty else {
            return .empty
        }

        let lines = try RichSyncParser.parse(body)
        return Lyrics(
            title: title,
            artist: artist,
            lines: lines,
            isSyllable: lines.contains { $0.hasRealWordTimings },
            sourceName: "Musixmatch RichSync"
        )
    }

    private func request<Response: Decodable>(
        method: String,
        queryItems: [URLQueryItem]
    ) async throws -> Response {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(method),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems + [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components.url else { throw MusixmatchError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Sonivo/1.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MusixmatchError.httpFailure
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

private enum MusixmatchError: Error {
    case invalidURL
    case httpFailure
}

private struct TrackSearchResponse: Decodable {
    struct Message: Decodable {
        struct Body: Decodable {
            struct Item: Decodable {
                struct TrackPayload: Decodable {
                    let trackID: Int
                    let trackName: String?
                    let artistName: String?

                    enum CodingKeys: String, CodingKey {
                        case trackID = "track_id"
                        case trackName = "track_name"
                        case artistName = "artist_name"
                    }
                }
                let track: TrackPayload
            }
            let trackList: [Item]

            enum CodingKeys: String, CodingKey {
                case trackList = "track_list"
            }
        }
        let body: Body
    }
    let message: Message
}

private struct SubtitleResponse: Decodable {
    struct Message: Decodable {
        struct Body: Decodable {
            struct Subtitle: Decodable {
                let subtitleBody: String

                enum CodingKeys: String, CodingKey {
                    case subtitleBody = "subtitle_body"
                }
            }
            let subtitle: Subtitle?
        }
        let body: Body
    }
    let message: Message
}

private struct RichSyncResponse: Decodable {
    struct Message: Decodable {
        struct Body: Decodable {
            struct RichSync: Decodable {
                let richsyncBody: String

                enum CodingKeys: String, CodingKey {
                    case richsyncBody = "richsync_body"
                }
            }
            let richsync: RichSync?
        }
        let body: Body
    }
    let message: Message
}

enum RichSyncParser {
    private struct RawLine: Decodable {
        struct Fragment: Decodable {
            let content: String
            let offset: TimeInterval

            enum CodingKeys: String, CodingKey {
                case content = "c"
                case offset = "o"
            }
        }

        let startTime: TimeInterval
        let endTime: TimeInterval?
        let text: String?
        let fragments: [Fragment]

        enum CodingKeys: String, CodingKey {
            case startTime = "ts"
            case endTime = "te"
            case text = "x"
            case fragments = "l"
        }
    }

    static func parse(_ body: String) throws -> [LyricsLine] {
        guard let data = body.data(using: .utf8) else { return [] }
        let rawLines = try JSONDecoder().decode([RawLine].self, from: data)
            .sorted { $0.startTime < $1.startTime }

        return rawLines.enumerated().compactMap { index, raw in
            let nextStart = index + 1 < rawLines.count ? rawLines[index + 1].startTime : nil
            let resolvedEnd = max(
                raw.startTime + 0.08,
                raw.endTime ?? nextStart ?? (raw.startTime + 4.0)
            )
            let ordered = raw.fragments.sorted { $0.offset < $1.offset }
            let words = ordered.enumerated().compactMap { fragmentIndex, fragment -> LyricsWord? in
                guard !fragment.content.isEmpty else { return nil }
                let start = raw.startTime + max(0, fragment.offset)
                let end: TimeInterval
                if fragmentIndex + 1 < ordered.count {
                    end = raw.startTime + max(fragment.offset, ordered[fragmentIndex + 1].offset)
                } else {
                    end = resolvedEnd
                }
                return LyricsWord(
                    text: fragment.content,
                    startTime: start,
                    endTime: max(start + 0.04, end)
                )
            }

            let combined = ordered.map(\.content).joined()
            let text = (raw.text?.isEmpty == false ? raw.text! : combined)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            return LyricsLine(
                text: text,
                startTime: raw.startTime,
                endTime: resolvedEnd,
                words: words.isEmpty ? nil : words
            )
        }
    }
}