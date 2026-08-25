import CryptoKit
import Foundation

// MARK: - Yandex Music API Service (Full Features with Rotor Fallback)

@MainActor
final class YandexMusicService: ObservableObject {
    static let shared = YandexMusicService()

    @Published var token: String {
        didSet {
            UserDefaults.standard.set(token, forKey: "ym.token")
            isAuthorized = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    @Published var isAuthorized: Bool = false

    static let apiBase = "https://api.music.yandex.net"
    static let secretSalt = "XGRlBW9FXlekgbPrRHuSiA"

    private init() {
        let saved = UserDefaults.standard.string(forKey: "ym.token") ?? ""
        self.token = saved
        self.isAuthorized = !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Models

    struct YMTrackItem: Identifiable, Codable, Equatable {
        let id: String
        let title: String
        let available: Bool?
        let durationMs: Int
        let coverUri: String?
        let artists: [YMArtist]?
        let albums: [YMAlbum]?

        var duration: Double { Double(durationMs) / 1000.0 }
        var artistName: String {
            artists?.compactMap(\.name).joined(separator: ", ") ?? "Неизвестный исполнитель"
        }
        var albumName: String {
            albums?.first?.title ?? "Сингл"
        }
        var coverUrlString: String? {
            guard let uri = coverUri else { return nil }
            return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
        }

        static func == (lhs: YMTrackItem, rhs: YMTrackItem) -> Bool { lhs.id == rhs.id }
    }

    struct YMArtist: Codable, Equatable {
        let id: Int?
        let name: String?
    }

    struct YMAlbum: Codable, Equatable {
        let id: Int?
        let title: String?
        let year: Int?
    }

    // MARK: - Search Tracks & Artists

    func search(query: String, page: Int = 0) async throws -> [YMTrackItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var components = URLComponents(string: "\(Self.apiBase)/search")!
        components.queryItems = [
            URLQueryItem(name: "text", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "nocorrect", value: "false")
        ]

        let req = authorizedRequest(url: components.url!)
        let (data, _) = try await URLSession.shared.data(for: req)

        struct SearchResponse: Codable {
            struct Result: Codable {
                struct TracksBlock: Codable {
                    let results: [YMTrackItem]?
                }
                let tracks: TracksBlock?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(SearchResponse.self, from: data)
        return resp.result?.tracks?.results ?? []
    }

    // MARK: - Russian & Global Chart (Чарт Яндекс Музыки)

    func getChart() async throws -> [YMTrackItem] {
        let url = URL(string: "\(Self.apiBase)/landing3/chart/russia")!
        let req = authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: req)

        struct ChartResponse: Codable {
            struct Result: Codable {
                struct ChartBlock: Codable {
                    struct ChartEntry: Codable {
                        let track: YMTrackItem?
                    }
                    let tracks: [ChartEntry]?
                }
                let chart: ChartBlock?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(ChartResponse.self, from: data)
        return resp.result?.chart?.tracks?.compactMap(\.track) ?? []
    }

    // MARK: - «Моя волна» / Radio Stations (Rotor with fallback)

    struct StationOption: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let stationId: String
        let gradient: [String]
        let icon: String
    }

    static let rotorStations: [StationOption] = [
        StationOption(id: "wave", title: "Моя волна", subtitle: "Бесконечный поток под ваш вкус", stationId: "user:onyourwave", gradient: ["#FF455B", "#9333EA"], icon: "waveform.badge.sparkles"),
        StationOption(id: "energy", title: "Энергичное", subtitle: "Для тренировок и активности", stationId: "activity:workout", gradient: ["#F97316", "#E11D48"], icon: "bolt.heart.fill"),
        StationOption(id: "relax", title: "Релакс и фон", subtitle: "Спокойная музыка без слов", stationId: "mood:calm", gradient: ["#06B6D4", "#3B82F6"], icon: "leaf.fill"),
        StationOption(id: "hits", title: "Главные хиты", subtitle: "Топовые треки этого месяца", stationId: "genre:pop", gradient: ["#EC4899", "#F43F5E"], icon: "flame.fill")
    ]

    func getStationTracks(stationId: String) async throws -> [YMTrackItem] {
        if isAuthorized {
            var components = URLComponents(string: "\(Self.apiBase)/rotor/station/\(stationId)/tracks")!
            components.queryItems = [URLQueryItem(name: "settings2", value: "true")]
            let req = authorizedRequest(url: components.url!)
            if let (data, _) = try? await URLSession.shared.data(for: req) {
                struct StationResponse: Codable {
                    struct Result: Codable {
                        struct SequenceEntry: Codable {
                            let track: YMTrackItem?
                        }
                        let sequence: [SequenceEntry]?
                    }
                    let result: Result?
                }
                if let resp = try? JSONDecoder().decode(StationResponse.self, from: data),
                   let list = resp.result?.sequence?.compactMap(\.track), !list.isEmpty {
                    return list
                }
            }
        }
        // Fallback to top chart / trending tracks so My Wave ALWAYS launches!
        return try await getChart()
    }

    // MARK: - Resolve Direct MP3 Streaming Link with MD5 Signature

    func getDirectStreamURL(for trackId: String) async throws -> URL {
        let downloadInfoListURL = URL(string: "\(Self.apiBase)/tracks/\(trackId)/download-info")!
        let req = authorizedRequest(url: downloadInfoListURL)
        let (data, _) = try await URLSession.shared.data(for: req)

        struct DownloadInfoEntry: Codable {
            let codec: String
            let bitrateInKbps: Int
            let downloadInfoUrl: String
            let direct: Bool?
        }
        struct DownloadInfoResponse: Codable {
            let result: [DownloadInfoEntry]?
        }

        let infoResp = try JSONDecoder().decode(DownloadInfoResponse.self, from: data)
        guard let list = infoResp.result, !list.isEmpty else {
            throw URLError(.cannotFindHost)
        }

        let best = list.filter { $0.codec.lowercased() == "mp3" }.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list[0]

        guard let xmlURL = URL(string: best.downloadInfoUrl) else { throw URLError(.badURL) }
        let (xmlData, _) = try await URLSession.shared.data(from: xmlURL)
        guard let xmlString = String(data: xmlData, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }

        let host = extractTag("host", from: xmlString)
        let path = extractTag("path", from: xmlString)
        let ts = extractTag("ts", from: xmlString)
        let s = extractTag("s", from: xmlString)

        guard !host.isEmpty, !path.isEmpty, !ts.isEmpty, !s.isEmpty else {
            throw URLError(.cannotParseResponse)
        }

        let pathWithoutLeadingSlash = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let signRaw = Self.secretSalt + pathWithoutLeadingSlash + s
        let sign = md5(signRaw)

        let finalURLString = "https://\(host)/get-mp3/\(sign)/\(ts)\(path)"
        guard let finalURL = URL(string: finalURLString) else { throw URLError(.badURL) }
        return finalURL
    }

    // MARK: - Convert YMTrackItem to App Track Model

    func convertToTrack(_ ym: YMTrackItem) -> Track {
        let numericSeed = Int(String(ym.id.prefix(6))) ?? 777
        return Track(
            id: UUID(),
            fileName: "ym_\(ym.id).mp3",
            relativePath: "",
            title: ym.title,
            artist: ym.artistName,
            album: ym.albumName,
            duration: ym.duration,
            artworkSeed: numericSeed,
            colorsHex: ["#FF455B", "#6366F1"],
            hasEmbeddedArtwork: false,
            isFavorite: false,
            addedAt: Date(),
            isStream: true,
            streamUrlString: ym.id
        )
    }

    // MARK: - Helpers

    private func authorizedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !token.isEmpty {
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
        req.setValue("WindowsPhone/4.75 (Windows Phone 8.1; Microsoft; Lumia 950)", forHTTPHeaderField: "User-Agent")
        req.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        return req
    }

    private func extractTag(_ tag: String, from xml: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let start = xml.range(of: open)?.upperBound,
              let end = xml.range(of: close, range: start..<xml.endIndex)?.lowerBound else {
            return ""
        }
        return String(xml[start..<end])
    }

    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
