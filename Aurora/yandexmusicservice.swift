import CryptoKit
import Foundation

// MARK: - Yandex Music API Service
// Каталог, Топ-100 чарт, новые релизы, персональная «Моя волна» без повторов
// и память прослушиваний (сервис понимает, что именно слушает пользователь).

@MainActor
final class YandexMusicService: ObservableObject {
    static let shared = YandexMusicService()

    // Default User Token for full 320kbps and unlimited streaming
    static let defaultToken = "y0__wgBEKKSlpUBGN74BiDN-cLlGKqO1NIws5NU7nK8VFyfbs9Ou9So"

    @Published var token: String {
        didSet {
            UserDefaults.standard.set(token, forKey: "ym.token")
            isAuthorized = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    @Published var isAuthorized: Bool = true

    // MARK: - Персональная память прослушиваний
    @Published private(set) var recentKeys: [String] = []
    @Published private(set) var totalPlays: Int = 0
    private var artistCounts: [String: Int] = [:]
    private(set) var activeStationId: String?
    private var lastBatchId: String?

    static let apiBase = "https://api.music.yandex.net"
    static let secretSalt = "XGRlBW9FXlekgbPrRHuSiA"

    private static let keyRecent = "ym.memory.recent"
    private static let keyArtists = "ym.memory.artists"
    private static let keyPlays = "ym.memory.plays"
    private static let memoryLimit = 600
    private static let noRepeatWindow = 180

    private var chartCache: [YMTrackItem] = []
    private var chartCacheAt: Date?
    private var newAlbumsCache: [YMAlbumItem] = []
    private var newAlbumsCacheAt: Date?
    private var newTracksCache: [YMTrackItem] = []

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "ym.token") ?? ""
        let activeToken = saved.isEmpty ? Self.defaultToken : saved
        self.token = activeToken
        self.isAuthorized = !activeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.recentKeys = defaults.stringArray(forKey: Self.keyRecent) ?? []
        self.artistCounts = (defaults.dictionary(forKey: Self.keyArtists) as? [String: Int]) ?? [:]
        self.totalPlays = defaults.integer(forKey: Self.keyPlays)
    }

    // MARK: - Models

    struct YMArtist: Codable, Equatable {
        let id: Int?
        let name: String?
    }

    struct YMAlbum: Codable, Equatable {
        let id: Int?
        let title: String?
        let year: Int?
        let coverUri: String?
    }

    struct YMTrackItem: Identifiable, Codable, Equatable {
        let id: String
        let title: String
        let available: Bool?
        let durationMs: Int
        let coverUri: String?
        let artists: [YMArtist]?
        let albums: [YMAlbum]?

        enum CodingKeys: String, CodingKey {
            case id, title, available, durationMs, coverUri, artists, albums
        }

        // Яндекс отдаёт id трека то строкой, то числом — принимаем оба варианта.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? c.decode(String.self, forKey: .id) {
                id = s
            } else if let n = try? c.decode(Int.self, forKey: .id) {
                id = String(n)
            } else {
                id = UUID().uuidString
            }
            title = (try? c.decode(String.self, forKey: .title)) ?? "Без названия"
            available = try? c.decode(Bool.self, forKey: .available)
            durationMs = (try? c.decode(Int.self, forKey: .durationMs)) ?? 0
            coverUri = try? c.decode(String.self, forKey: .coverUri)
            artists = try? c.decode([YMArtist].self, forKey: .artists)
            albums = try? c.decode([YMAlbum].self, forKey: .albums)
        }

        var duration: Double { Double(durationMs) / 1000.0 }

        var artistName: String {
            let names = (artists ?? []).compactMap { $0.name }
            return names.isEmpty ? "Неизвестный исполнитель" : names.joined(separator: ", ")
        }

        var albumName: String { albums?.first?.title ?? "Сингл" }

        var coverUrlString: String? {
            let raw = coverUri ?? albums?.first?.coverUri
            guard let uri = raw, !uri.isEmpty else { return nil }
            return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
        }

        static func == (lhs: YMTrackItem, rhs: YMTrackItem) -> Bool { lhs.id == rhs.id }
    }

    struct YMAlbumItem: Identifiable, Codable, Equatable {
        let id: Int
        let title: String?
        let coverUri: String?
        let year: Int?
        let genre: String?
        let trackCount: Int?
        let artists: [YMArtist]?

        enum CodingKeys: String, CodingKey {
            case id, title, coverUri, year, genre, trackCount, artists
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let n = try? c.decode(Int.self, forKey: .id) {
                id = n
            } else if let s = try? c.decode(String.self, forKey: .id), let n = Int(s) {
                id = n
            } else {
                id = 0
            }
            title = try? c.decode(String.self, forKey: .title)
            coverUri = try? c.decode(String.self, forKey: .coverUri)
            year = try? c.decode(Int.self, forKey: .year)
            genre = try? c.decode(String.self, forKey: .genre)
            trackCount = try? c.decode(Int.self, forKey: .trackCount)
            artists = try? c.decode([YMArtist].self, forKey: .artists)
        }

        var displayTitle: String { title ?? "Без названия" }

        var artistName: String {
            let names = (artists ?? []).compactMap { $0.name }
            return names.isEmpty ? "Разные исполнители" : names.joined(separator: ", ")
        }

        var coverUrlString: String? {
            guard let uri = coverUri, !uri.isEmpty else { return nil }
            return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
        }

        static func == (lhs: YMAlbumItem, rhs: YMAlbumItem) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Search

    func search(query: String, page: Int = 0) async throws -> [YMTrackItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var components = URLComponents(string: Self.apiBase + "/search")!
        components.queryItems = [
            URLQueryItem(name: "text", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "nocorrect", value: "false")
        ]

        let req = authorizedRequest(url: components.url!)
        let (data, _) = try await URLSession.shared.data(for: req)

        struct SearchResponse: Decodable {
            struct Result: Decodable {
                struct TracksBlock: Decodable {
                    let results: [YMTrackItem]?
                }
                let tracks: TracksBlock?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(SearchResponse.self, from: data)
        return Self.playable(resp.result?.tracks?.results ?? [])
    }

    // MARK: - Топ-100 чарт

    func getChart(force: Bool = false) async throws -> [YMTrackItem] {
        if !force, !chartCache.isEmpty, let at = chartCacheAt, Date().timeIntervalSince(at) < 900 {
            return chartCache
        }

        let url = URL(string: Self.apiBase + "/landing3/chart/russia")!
        let req = authorizedRequest(url: url)
        let (data, _) = try await URLSession.shared.data(for: req)

        struct ChartResponse: Decodable {
            struct Result: Decodable {
                struct ChartBlock: Decodable {
                    struct ChartEntry: Decodable {
                        let track: YMTrackItem?
                    }
                    let tracks: [ChartEntry]?
                }
                let chart: ChartBlock?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(ChartResponse.self, from: data)
        let list = (resp.result?.chart?.tracks ?? []).compactMap { $0.track }
        let top = Array(Self.playable(list).prefix(100))
        chartCache = top
        chartCacheAt = Date()
        return top
    }

    // MARK: - Новые релизы (альбомы и синглы)

    func getNewAlbums(force: Bool = false) async throws -> [YMAlbumItem] {
        if !force, !newAlbumsCache.isEmpty, let at = newAlbumsCacheAt, Date().timeIntervalSince(at) < 1800 {
            return newAlbumsCache
        }

        var ids = (try? await newReleaseIds()) ?? []
        if ids.isEmpty {
            ids = (try? await landingBlockAlbumIds()) ?? []
        }
        guard !ids.isEmpty else { return newAlbumsCache }

        let albums = try await fetchAlbums(ids: Array(ids.prefix(40)))
        let clean = albums.filter { $0.id != 0 }
        if !clean.isEmpty {
            newAlbumsCache = clean
            newAlbumsCacheAt = Date()
        }
        return clean
    }

    private func newReleaseIds() async throws -> [Int] {
        let url = URL(string: Self.apiBase + "/landing3/new-releases")!
        let (data, _) = try await URLSession.shared.data(for: authorizedRequest(url: url))

        struct Response: Decodable {
            struct Result: Decodable {
                let newReleases: [Int]?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(Response.self, from: data)
        return resp.result?.newReleases ?? []
    }

    private func landingBlockAlbumIds() async throws -> [Int] {
        var comps = URLComponents(string: Self.apiBase + "/landing3")!
        comps.queryItems = [URLQueryItem(name: "blocks", value: "new-releases")]
        let (data, _) = try await URLSession.shared.data(for: authorizedRequest(url: comps.url!))

        struct Response: Decodable {
            struct Result: Decodable {
                struct Block: Decodable {
                    struct Entity: Decodable {
                        struct Payload: Decodable { let id: Int? }
                        let data: Payload?
                    }
                    let entities: [Entity]?
                }
                let blocks: [Block]?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(Response.self, from: data)
        let blocks = resp.result?.blocks ?? []
        return blocks.flatMap { $0.entities ?? [] }.compactMap { $0.data?.id }
    }

    func fetchAlbums(ids: [Int]) async throws -> [YMAlbumItem] {
        guard !ids.isEmpty else { return [] }
        let url = URL(string: Self.apiBase + "/albums")!
        var req = authorizedRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let joined = ids.map { String($0) }.joined(separator: "%2C")
        req.httpBody = ("album-ids=" + joined).data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)

        struct Response: Decodable {
            let result: [YMAlbumItem]?
        }

        let resp = try JSONDecoder().decode(Response.self, from: data)
        return resp.result ?? []
    }

    func getAlbumTracks(albumId: Int) async throws -> [YMTrackItem] {
        let url = URL(string: Self.apiBase + "/albums/" + String(albumId) + "/with-tracks")!
        let (data, _) = try await URLSession.shared.data(for: authorizedRequest(url: url))

        struct Response: Decodable {
            struct Result: Decodable {
                let volumes: [[YMTrackItem]]?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(Response.self, from: data)
        let volumes = resp.result?.volumes ?? []
        return Self.playable(volumes.flatMap { $0 })
    }

    /// Свежие треки — по одному-двум из каждого нового релиза.
    func getNewTracks(limit: Int = 24) async -> [YMTrackItem] {
        if !newTracksCache.isEmpty { return newTracksCache }
        let albums = (try? await getNewAlbums()) ?? []
        var out: [YMTrackItem] = []
        var seen = Set<String>()

        for album in albums.prefix(10) {
            if out.count >= limit { break }
            let tracks = (try? await getAlbumTracks(albumId: album.id)) ?? []
            for item in tracks.prefix(2) {
                if seen.contains(item.id) { continue }
                seen.insert(item.id)
                out.append(item)
            }
        }

        if !out.isEmpty { newTracksCache = out }
        return out
    }

    // MARK: - Радиостанции / «Моя волна»

    struct StationOption: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let stationId: String
        let gradient: [String]
        let icon: String
    }

    static let rotorStations: [StationOption] = [
        StationOption(id: "wave", title: "Моя волна", subtitle: "Бесконечный поток без повторов", stationId: "user:onyourwave", gradient: ["#FBBF24", "#EA580C"], icon: "waveform.badge.sparkles"),
        StationOption(id: "energy", title: "Энергия", subtitle: "Для тренировок и движения", stationId: "activity:workout", gradient: ["#F97316", "#B91C1C"], icon: "bolt.heart.fill"),
        StationOption(id: "relax", title: "Релакс", subtitle: "Спокойное на фон", stationId: "mood:calm", gradient: ["#FCD34D", "#B45309"], icon: "leaf.fill"),
        StationOption(id: "hits", title: "Главные хиты", subtitle: "Топовое прямо сейчас", stationId: "genre:pop", gradient: ["#FB923C", "#9A3412"], icon: "flame.fill"),
        StationOption(id: "rap", title: "Рэп и хип-хоп", subtitle: "Свежие биты", stationId: "genre:rap", gradient: ["#F59E0B", "#7C2D12"], icon: "mic.fill"),
        StationOption(id: "electronic", title: "Электроника", subtitle: "Клубный настрой", stationId: "genre:electronics", gradient: ["#FDE68A", "#EA580C"], icon: "waveform.path.ecg")
    ]

    func getStationTracks(stationId: String) async throws -> [YMTrackItem] {
        let batch = await fetchRotorBatch(stationId: stationId, queueSeed: nil)
        if !batch.isEmpty { return batch }
        return try await getChart()
    }

    /// Собирает длинную очередь волны без повторов: несколько батчей ротора
    /// подряд, с фильтрацией по истории прослушиваний.
    func buildWaveQueue(stationId: String = "user:onyourwave", target: Int = 45) async -> [YMTrackItem] {
        var collected: [YMTrackItem] = []
        var seen = Set<String>()
        var seed: String?

        for _ in 0..<6 {
            let batch = await fetchRotorBatch(stationId: stationId, queueSeed: seed)
            if batch.isEmpty { break }
            for item in batch {
                if seen.contains(item.id) { continue }
                seen.insert(item.id)
                if isRecentlyPlayed(ymTrackId: item.id) { continue }
                collected.append(item)
            }
            seed = batch.last?.id
            if collected.count >= target { break }
        }

        if collected.count < 12 {
            let extra = await personalPicks(limit: max(0, target - collected.count), excluding: seen)
            collected.append(contentsOf: extra)
        }

        return Array(collected.prefix(target))
    }

    /// Подборка на основе того, что пользователь реально слушает.
    func personalPicks(limit: Int, excluding: Set<String> = []) async -> [YMTrackItem] {
        guard limit > 0 else { return [] }
        var used = excluding
        var out: [YMTrackItem] = []

        for artist in topArtists.shuffled().prefix(8) {
            if out.count >= limit { break }
            let found = (try? await search(query: artist)) ?? []
            for item in found.prefix(6) {
                if out.count >= limit { break }
                if used.contains(item.id) { continue }
                if isRecentlyPlayed(ymTrackId: item.id) { continue }
                used.insert(item.id)
                out.append(item)
            }
        }

        if out.count < limit {
            let chart = (try? await getChart()) ?? []
            for item in chart.shuffled() {
                if out.count >= limit { break }
                if used.contains(item.id) { continue }
                used.insert(item.id)
                out.append(item)
            }
        }

        return out
    }

    private func fetchRotorBatch(stationId: String, queueSeed: String?) async -> [YMTrackItem] {
        guard var comps = URLComponents(string: Self.apiBase + "/rotor/station/" + stationId + "/tracks") else { return [] }
        var items = [URLQueryItem(name: "settings2", value: "true")]
        if let queueSeed { items.append(URLQueryItem(name: "queue", value: queueSeed)) }
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        guard let pair = try? await URLSession.shared.data(for: authorizedRequest(url: url)) else { return [] }

        struct StationResponse: Decodable {
            struct Result: Decodable {
                struct SequenceEntry: Decodable {
                    let track: YMTrackItem?
                }
                let sequence: [SequenceEntry]?
                let batchId: String?
            }
            let result: Result?
        }

        guard let resp = try? JSONDecoder().decode(StationResponse.self, from: pair.0) else { return [] }
        if let batch = resp.result?.batchId { lastBatchId = batch }
        let list = (resp.result?.sequence ?? []).compactMap { $0.track }
        return Self.playable(list)
    }

    /// Обратная связь ротору — так «Моя волна» учится на прослушиваниях.
    func sendRotorFeedback(stationId: String, type: String, trackId: String? = nil, totalPlayedSeconds: Double? = nil) async {
        guard var comps = URLComponents(string: Self.apiBase + "/rotor/station/" + stationId + "/feedback") else { return }
        if let batch = lastBatchId {
            comps.queryItems = [URLQueryItem(name: "batch-id", value: batch)]
        }
        guard let url = comps.url else { return }

        var req = authorizedRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["type": type, "timestamp": Date().timeIntervalSince1970]
        if let trackId { body["trackId"] = trackId }
        if let totalPlayedSeconds { body["totalPlayedSeconds"] = totalPlayedSeconds }
        if type == "radioStarted" { body["from"] = "sonivo-ios" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await URLSession.shared.data(for: req)
    }

    func beginStationSession(_ stationId: String) {
        activeStationId = stationId
        Task { await sendRotorFeedback(stationId: stationId, type: "radioStarted") }
    }

    func endStationSession() {
        activeStationId = nil
    }

    // MARK: - Память прослушиваний

    static func stableKey(for ymTrackId: String) -> String {
        stableID(from: ymTrackId).uuidString
    }

    static func ymId(fromFileName name: String) -> String? {
        guard name.hasPrefix("ym_"), name.hasSuffix(".mp3") else { return nil }
        let core = String(name.dropFirst(3).dropLast(4))
        return core.isEmpty ? nil : core
    }

    func remember(key: String, artist: String?, ymTrackId: String?) {
        var keys = recentKeys.filter { $0 != key }
        keys.insert(key, at: 0)
        if keys.count > Self.memoryLimit { keys = Array(keys.prefix(Self.memoryLimit)) }
        recentKeys = keys
        totalPlays += 1

        let defaults = UserDefaults.standard
        defaults.set(keys, forKey: Self.keyRecent)
        defaults.set(totalPlays, forKey: Self.keyPlays)

        if let artist, !artist.isEmpty, artist != "Неизвестный исполнитель" {
            let parts = artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for name in parts where !name.isEmpty {
                artistCounts[name, default: 0] += 1
            }
            defaults.set(artistCounts, forKey: Self.keyArtists)
        }

        if let station = activeStationId, let ymTrackId {
            Task { await sendRotorFeedback(stationId: station, type: "trackStarted", trackId: ymTrackId) }
        }
    }

    func isRecentlyPlayed(ymTrackId: String) -> Bool {
        recentKeys.prefix(Self.noRepeatWindow).contains(Self.stableKey(for: ymTrackId))
    }

    var topArtists: [String] {
        artistCounts.sorted { $0.value > $1.value }.prefix(14).map { $0.key }
    }

    var waveSubtitle: String {
        if totalPlays < 5 { return "Бесконечный поток — подстроится под ваш вкус" }
        if let favourite = topArtists.first {
            return "Без повторов · " + String(totalPlays) + " прослушиваний · любите " + favourite
        }
        return "Без повторов · учтено " + String(totalPlays) + " прослушиваний"
    }

    func clearMemory() {
        recentKeys = []
        artistCounts = [:]
        totalPlays = 0
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.keyRecent)
        defaults.removeObject(forKey: Self.keyArtists)
        defaults.removeObject(forKey: Self.keyPlays)
    }

    // MARK: - Resolve Direct MP3 Streaming Link with MD5 Signature

    struct StreamInfo {
        let url: URL
        let bitrate: Int
        let codec: String
    }

    func getDirectStreamURL(for trackId: String) async throws -> URL {
        try await getStreamInfo(for: trackId).url
    }

    func getStreamInfo(for trackId: String, preferredBitrate: Int? = nil) async throws -> StreamInfo {
        let downloadInfoListURL = URL(string: Self.apiBase + "/tracks/" + trackId + "/download-info")!
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

        let mp3 = list.filter { $0.codec.lowercased() == "mp3" }
        let best: DownloadInfoEntry
        if let preferred = preferredBitrate {
            best = mp3.min(by: { abs($0.bitrateInKbps - preferred) < abs($1.bitrateInKbps - preferred) }) ?? list[0]
        } else {
            best = mp3.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list[0]
        }

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

        let finalURLString = "https://" + host + "/get-mp3/" + sign + "/" + ts + path
        guard let finalURL = URL(string: finalURLString) else { throw URLError(.badURL) }
        return StreamInfo(url: finalURL, bitrate: best.bitrateInKbps, codec: best.codec)
    }

    // MARK: - Convert YMTrackItem to App Track Model

    func convertToTrack(_ ym: YMTrackItem) -> Track {
        let numericSeed = Int(String(ym.id.prefix(6))) ?? 777
        return Track(
            id: Self.stableID(from: ym.id),
            fileName: "ym_" + ym.id + ".mp3",
            relativePath: "",
            title: ym.title,
            artist: ym.artistName,
            album: ym.albumName,
            duration: ym.duration,
            artworkSeed: numericSeed,
            colorsHex: ["#FBBF24", "#EA580C"],
            hasEmbeddedArtwork: false,
            isFavorite: false,
            addedAt: Date(),
            isStream: true,
            streamUrlString: ym.id,
            coverURL: ym.coverUrlString
        )
    }

    // MARK: - Helpers

    static func playable(_ items: [YMTrackItem]) -> [YMTrackItem] {
        var seen = Set<String>()
        var out: [YMTrackItem] = []
        for item in items {
            if item.available == false { continue }
            if seen.contains(item.id) { continue }
            seen.insert(item.id)
            out.append(item)
        }
        return out
    }

    /// Детерминированный UUID из строки — один и тот же Yandex track id всегда даёт один UUID.
    private static func stableID(from string: String) -> UUID {
        let bytes = Array(Insecure.MD5.hash(data: Data(string.utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let activeToken = token.isEmpty ? Self.defaultToken : token
        req.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
        req.setValue("WindowsPhone/4.75 (Windows Phone 8.1; Microsoft; Lumia 950)", forHTTPHeaderField: "User-Agent")
        req.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        return req
    }

    private func extractTag(_ tag: String, from xml: String) -> String {
        let open = "<" + tag + ">"
        let close = "</" + tag + ">"
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
