import CryptoKit
import Foundation
import Observation

// MARK: - Yandex Music API Service
// Глобальный поиск, страницы артистов и альбомов, Топ-100 чарт, новые релизы,
// персональная «Моя волна» без повторов под выбранное настроение
// и память прослушиваний (сервис понимает, что именно слушает пользователь).

@Observable
@MainActor
final class YandexMusicService {
    static let shared = YandexMusicService()

    private(set) var token: String = ""
    private(set) var isAuthorized = false
    private var credential: YandexCredential?
    private(set) var accountGeneration = UUID()
    private var loginAttemptID = UUID()
    private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var accountSyncTask: Task<Void, Never>?
    @ObservationIgnored private var accountSyncGeneration: UUID?
    @ObservationIgnored private var accountSyncRequestID = UUID()
    private(set) var accountSyncMessage: String?
    private(set) var currentUser: YMUserProfile? = nil
    var isUserLoggedIn: Bool {
        currentUser != nil
    }

    // MARK: - Персональная память прослушиваний
    private(set) var recentKeys: [String] = []
    private(set) var totalPlays: Int = 0
    private var artistCounts: [String: Int] = [:]
    private(set) var activeStationId: String?
    @ObservationIgnored private lazy var waveSession = YandexWaveSession<YMTrackItem>(
        send: { [weak self] request in
            guard let self else { throw CancellationError() }
            return try await self.sessionData(for: request)
        }, identity: { $0.id }, playable: { [weak self] item in
            guard item.available != false, let self else { return false }
            return !UserTasteEngine.shared.isDisliked(track: self.convertToTrack(item))
        },
        log: { SonivoDiagnostics.log($0, tag: "WAVE") })
    private(set) var waveError: String?
    private(set) var appliedWaveSettings: [String: String]?
    private(set) var rotorSessionID = UUID()
    private var trackStationRequestID = UUID()

    /// Выбранное настроение волны (stationId ротора).
    var waveMoodStationId: String = "user:onyourwave" {
        didSet { UserDefaults.standard.set(waveMoodStationId, forKey: "ym.waveMood") }
    }

    static let apiBase = "https://api.music.yandex.net"
    static let secretSalt = "XGRlBW9FXlekgbPrRHuSiA"

    private static let keyRecent = "ym.memory.recent"
    private static let keyRecentYm = "ym.memory.recent_ym_ids"
    private static let keyArtists = "ym.memory.artists"
    private static let keyPlays = "ym.memory.plays"
    private static let keyPremiereTracks = "sonivo.premiere.tracks.v2"
    private static let keyPremiereDate = "sonivo.premiere.cached_date.v2"
    private static let memoryLimit = 600
    private static let noRepeatWindow = 200

    private(set) var recentYmIDs: [String] = []
    private(set) var chartCache: [YMTrackItem] = []
    private var chartCacheAt: Date?
    private var newAlbumsCache: [YMAlbumItem] = []
    private var newAlbumsCacheAt: Date?
    private(set) var newTracksCache: [YMTrackItem] = []
    private(set) var newTracksCacheAt: Date?
    private var artistCache: [String: YMArtistItem] = [:]
    private var artistTracksCache: [String: [YMTrackItem]] = [:]

    /// Валидность суточного кэша премьер (до 00:00).
    var isDailyPremiereCacheValid: Bool {
        guard let at = newTracksCacheAt, !newTracksCache.isEmpty else { return false }
        return Calendar.current.isDateInToday(at)
    }

    private func saveDailyPremiereCache(_ tracks: [YMTrackItem]) {
        guard !tracks.isEmpty else { return }
        let now = Date()
        self.newTracksCache = tracks
        self.newTracksCacheAt = now
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: Self.keyPremiereTracks)
            UserDefaults.standard.set(now, forKey: Self.keyPremiereDate)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        // Old builds shipped a common token. Require explicit personal sign-in instead
        // of importing an unverified token or trusting its cached profile.
        defaults.removeObject(forKey: "ym.token")
        self.credential = YandexCredentialStore.read()
        self.token = credential?.accessToken ?? ""
        self.isAuthorized = !token.isEmpty
        self.recentKeys = defaults.stringArray(forKey: Self.keyRecent) ?? []
        self.recentYmIDs = defaults.stringArray(forKey: Self.keyRecentYm) ?? []
        self.artistCounts = (defaults.dictionary(forKey: Self.keyArtists) as? [String: Int]) ?? [:]
        self.totalPlays = defaults.integer(forKey: Self.keyPlays)
        self.waveMoodStationId = defaults.string(forKey: "ym.waveMood") ?? "user:onyourwave"

        if let uData = defaults.data(forKey: "ym.user_profile"),
           let savedProfile = try? JSONDecoder().decode(YMUserProfile.self, from: uData),
           savedProfile.uid == credential?.uid {
            self.currentUser = savedProfile
        }

        // Восстановление суточного кэша Топ-100 премьер, если он сохранен сегодня (до 00:00)
        if let pData = defaults.data(forKey: Self.keyPremiereTracks),
           let savedDate = defaults.object(forKey: Self.keyPremiereDate) as? Date,
           Calendar.current.isDateInToday(savedDate),
           let tracks = try? JSONDecoder().decode([YMTrackItem].self, from: pData),
           !tracks.isEmpty {
            self.newTracksCache = tracks
            self.newTracksCacheAt = savedDate
        }
        if credential == nil {
            defaults.removeObject(forKey: "ym.user_profile")
            resetPersonalState()
            LibraryStore.shared.clearYandexAccountData()
        } else {
            Task { await syncAccountData() }
        }
    }

    // MARK: - Models

    struct YMUserProfile: Codable, Equatable, Sendable {
        let uid: Int
        let login: String
        let displayName: String?
        let fullName: String?
        let avatarUrl: String?
        let hasPlus: Bool
    }

    nonisolated struct YMArtist: Codable, Equatable, Sendable {
        let id: Int?
        let name: String?
    }

    nonisolated struct YMAlbum: Codable, Equatable, Sendable {
        let id: Int?
        let title: String?
        let year: Int?
        let coverUri: String?
    }

    nonisolated struct YMTrackItem: Identifiable, Codable, Equatable, Sendable {
        let id: String
        let title: String
        let version: String?
        let available: Bool?
        let durationMs: Int
        let coverUri: String?
        let artists: [YMArtist]?
        let albums: [YMAlbum]?

        enum CodingKeys: String, CodingKey {
            case id, title, version, available, durationMs, coverUri, artists, albums
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try? c.decode(String.self, forKey: .id) {
                id = s
            } else if let n = try? c.decode(Int.self, forKey: .id) {
                id = String(n)
            } else {
                id = UUID().uuidString
            }
            let baseTitle = (try? c.decode(String.self, forKey: .title)) ?? "Без названия"
            version = try? c.decode(String.self, forKey: .version)
            title = LyricsMatchPolicy.recordingTitle(baseTitle, version: version)
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

    /// Полная карточка артиста с популярными треками и альбомами.
    struct YMArtistItem: Identifiable, Equatable {
        let id: String
        let name: String
        let coverUri: String?
        let genres: [String]
        let counts: ArtistCounts?
        var popularTracks: [YMTrackItem] = []
        var albums: [YMAlbumItem] = []
        var similarArtists: [YMArtistBrief] = []

        struct ArtistCounts: Equatable {
            let tracks: Int?
            let directAlbums: Int?
        }

        struct YMArtistBrief: Identifiable, Equatable {
            let id: String
            let name: String
            let coverUri: String?
            var coverUrlString: String? {
                guard let uri = coverUri, !uri.isEmpty else { return nil }
                return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
            }
        }

        var coverUrlString: String? {
            guard let uri = coverUri, !uri.isEmpty else { return nil }
            return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
        }

        var subtitle: String {
            var parts: [String] = []
            if let c = counts?.tracks { parts.append(String(c) + " треков") }
            if let g = genres.first { parts.append(g.capitalized) }
            return parts.joined(separator: " · ")
        }
    }

    /// Результат глобального поиска.
    struct GlobalSearchResults {
        var tracks: [YMTrackItem] = []
        var artists: [YMArtistBrief] = []
        var albums: [YMAlbumItem] = []
        var suggestions: [String] = []
    }

    // MARK: - Global Search (треки + артисты + альбомы + подсказки)

    /// Глобальный поиск по всей базе Яндекс.Музыки.
    func searchAll(query: String) async -> GlobalSearchResults {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return GlobalSearchResults() }
        guard var comps = URLComponents(string: Self.apiBase + "/search") else { return GlobalSearchResults() }
        comps.queryItems = [
            URLQueryItem(name: "text", value: query),
            URLQueryItem(name: "type", value: "all"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "nocorrect", value: "false")
        ]
        guard let url = comps.url,
              let pair = try? await sessionData(for: authorizedRequest(url: url)) else {
            return GlobalSearchResults()
        }

        struct Response: Decodable {
            struct Result: Decodable {
                struct TracksBlock: Decodable { let results: [YMTrackItem]? }
                struct ArtistsBlock: Decodable {
                    struct Raw: Decodable {
                        let id: Int?
                        let name: String?
                        let coverUri: String?
                        enum CodingKeys: String, CodingKey { case id, name, coverUri }
                    }
                    let results: [Raw]?
                }
                struct AlbumsBlock: Decodable { let results: [YMAlbumItem]? }
                let tracks: TracksBlock?
                let artists: ArtistsBlock?
                let albums: AlbumsBlock?
                let best: BestBlock?
                struct BestBlock: Decodable {
                    let type: String?
                    let result: BestResult?
                    struct BestResult: Decodable {
                        let id: Int?
                        let name: String?
                    }
                }
            }
            let result: Result?
        }

        guard let resp = try? JSONDecoder().decode(Response.self, from: pair.0) else {
            return GlobalSearchResults()
        }

        var out = GlobalSearchResults()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)

        // Треки — точный ранкер
        var tracks = Self.playable(resp.result?.tracks?.results ?? [])
        tracks.sort { a, b in
            let aArtistExact = a.artists?.contains(where: { ($0.name ?? "").lowercased() == q }) == true
            let bArtistExact = b.artists?.contains(where: { ($0.name ?? "").lowercased() == q }) == true
            if aArtistExact != bArtistExact { return aArtistExact }
            let aTitleExact = a.title.lowercased() == q
            let bTitleExact = b.title.lowercased() == q
            if aTitleExact != bTitleExact { return aTitleExact }
            let aTitleHas = a.title.lowercased().contains(q)
            let bTitleHas = b.title.lowercased().contains(q)
            if aTitleHas != bTitleHas { return aTitleHas }
            return a.title.count < b.title.count
        }
        out.tracks = tracks

        // Артисты
        let rawArtists = resp.result?.artists?.results ?? []
        var artists = rawArtists.compactMap { raw -> YMArtistItem.YMArtistBrief? in
            guard let id = raw.id, let name = raw.name else { return nil }
            return YMArtistItem.YMArtistBrief(id: String(id), name: name, coverUri: raw.coverUri)
        }
        artists.sort { a, b in
            let aExact = a.name.lowercased() == q
            let bExact = b.name.lowercased() == q
            if aExact != bExact { return aExact }
            return a.name.count < b.name.count
        }
        out.artists = artists

        // Альбомы
        var albums = (resp.result?.albums?.results ?? []).filter { $0.id != 0 }
        albums.sort { a, b in
            let aArtistExact = a.artists?.contains(where: { ($0.name ?? "").lowercased() == q }) == true
            let bArtistExact = b.artists?.contains(where: { ($0.name ?? "").lowercased() == q }) == true
            if aArtistExact != bArtistExact { return aArtistExact }
            let aTitleExact = a.displayTitle.lowercased() == q
            let bTitleExact = b.displayTitle.lowercased() == q
            if aTitleExact != bTitleExact { return aTitleExact }
            return (b.year ?? 0) > (a.year ?? 0)
        }
        out.albums = albums

        return out
    }

    /// Подсказки для поиска (точность ввода).
    func searchSuggestions(query: String) async -> [String] {
        guard query.count >= 2 else { return [] }
        guard var comps = URLComponents(string: Self.apiBase + "/search/suggest") else { return [] }
        comps.queryItems = [URLQueryItem(name: "part", value: query)]
        guard let url = comps.url,
              let pair = try? await sessionData(for: authorizedRequest(url: url)) else { return [] }
        struct Response: Decodable {
            struct Result: Decodable { let suggestions: [String]? }
            let result: Result?
        }
        return (try? JSONDecoder().decode(Response.self, from: pair.0))?.result?.suggestions ?? []
    }

    /// Легаси-метод для обратной совместимости — теперь использует глобальный ранкер.
    func search(query: String, page: Int = 0) async throws -> [YMTrackItem] {
        let all = await searchAll(query: query)
        return all.tracks
    }

    // MARK: - Страница артиста

    func getArtist(artistId: String) async throws -> YMArtistItem {
        if let cached = artistCache[artistId] { return cached }
        guard var comps = URLComponents(string: Self.apiBase + "/artists/" + artistId + "/brief-info") else { throw URLError(.badURL) }
        comps.queryItems = [
            URLQueryItem(name: "popularTracks", value: "true"),
            URLQueryItem(name: "discography", value: "true"),
            URLQueryItem(name: "similarArtists", value: "true")
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        let (data, _) = try await sessionData(for: authorizedRequest(url: url))

        struct Response: Decodable {
            struct Result: Decodable {
                struct ArtistBlock: Decodable {
                    let id: Int?
                    let name: String?
                    let coverUri: String?
                    let genres: [String]?
                    let counts: Counts?
                    struct Counts: Decodable {
                        let tracks: Int?
                        let directAlbums: Int?
                    }
                }
                let artist: ArtistBlock?
                struct TracksBlock: Decodable { let tracks: [YMTrackItem]? }
                struct AlbumsBlock: Decodable { let albums: [YMAlbumItem]? }
                struct SimilarBlock: Decodable {
                    struct Raw: Decodable {
                        let id: Int?
                        let name: String?
                        let coverUri: String?
                    }
                    let similarArtists: [Raw]?
                }
                let popularTracks: TracksBlock?
                let discography: AlbumsBlock?
                let similarArtists: SimilarBlock?
            }
            let result: Result?
        }

        let resp = try JSONDecoder().decode(Response.self, from: data)
        guard let raw = resp.result?.artist,
              let id = raw.id,
              let name = raw.name else { throw URLError(.cannotParseResponse) }

        var item = YMArtistItem(
            id: String(id),
            name: name,
            coverUri: raw.coverUri,
            genres: raw.genres ?? [],
            counts: YMArtistItem.ArtistCounts(tracks: raw.counts?.tracks, directAlbums: raw.counts?.directAlbums)
        )
        item.popularTracks = Self.playable(resp.result?.popularTracks?.tracks ?? [])
        item.albums = (resp.result?.discography?.albums ?? []).filter { $0.id != 0 }
        item.similarArtists = (resp.result?.similarArtists?.similarArtists ?? []).compactMap { raw in
            guard let id = raw.id, let name = raw.name else { return nil }
            return YMArtistItem.YMArtistBrief(id: String(id), name: name, coverUri: raw.coverUri)
        }

        artistCache[artistId] = item
        return item
    }

    /// Популярные треки артиста (отдельно, если нужно больше).
    func getArtistTracks(artistId: String, page: Int = 0, pageSize: Int = 30) async throws -> [YMTrackItem] {
        let key = artistId + ":" + String(page)
        if let cached = artistTracksCache[key] { return cached }
        guard var comps = URLComponents(string: Self.apiBase + "/artists/" + artistId + "/tracks") else { throw URLError(.badURL) }
        comps.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page-size", value: String(pageSize)),
            URLQueryItem(name: "sort", value: "plays")
        ]
        guard let url = comps.url else { throw URLError(.badURL) }
        let (data, _) = try await sessionData(for: authorizedRequest(url: url))
        struct Response: Decodable {
            struct Result: Decodable { let tracks: [YMTrackItem]? }
            let result: Result?
        }
        let list = Self.playable((try JSONDecoder().decode(Response.self, from: data)).result?.tracks ?? [])
        artistTracksCache[key] = list
        return list
    }

    // MARK: - Топ-100 чарт

    func getChart(force: Bool = false) async throws -> [YMTrackItem] {
        if !force, !chartCache.isEmpty, let at = chartCacheAt, Date().timeIntervalSince(at) < 900 {
            return chartCache
        }

        guard let url = URL(string: Self.apiBase + "/landing3/chart/russia") else { throw URLError(.badURL) }
        let req = authorizedRequest(url: url)
        let (data, _) = try await sessionData(for: req)

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
        let generation = accountGeneration
        if !force, !newAlbumsCache.isEmpty, let at = newAlbumsCacheAt, Date().timeIntervalSince(at) < 1800 {
            return newAlbumsCache
        }

        var ids = (try? await newReleaseIds()) ?? []
        if ids.isEmpty {
            ids = (try? await landingBlockAlbumIds()) ?? []
        }
        guard !ids.isEmpty else { return newAlbumsCache }

        let albums = try await fetchAlbums(ids: Array(ids.prefix(70)))
        guard accountGeneration == generation, !Task.isCancelled else { throw CancellationError() }
        let clean = albums.filter { $0.id != 0 }
        if !clean.isEmpty {
            newAlbumsCache = clean
            newAlbumsCacheAt = Date()
        }
        return clean
    }

    private func newReleaseIds() async throws -> [Int] {
        guard let url = URL(string: Self.apiBase + "/landing3/new-releases") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await sessionData(for: authorizedRequest(url: url))

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
        guard var comps = URLComponents(string: Self.apiBase + "/landing3") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [URLQueryItem(name: "blocks", value: "new-releases")]
        guard let url = comps.url else { throw URLError(.badURL) }
        let (data, _) = try await sessionData(for: authorizedRequest(url: url))

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
        guard let url = URL(string: Self.apiBase + "/albums") else { throw URLError(.badURL) }
        var req = authorizedRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let joined = ids.map { String($0) }.joined(separator: "%2C")
        req.httpBody = ("album-ids=" + joined).data(using: .utf8)
        let (data, _) = try await sessionData(for: req)

        struct Response: Decodable {
            let result: [YMAlbumItem]?
        }

        let resp = try JSONDecoder().decode(Response.self, from: data)
        return resp.result ?? []
    }

    /// Потокобезопасная загрузка треков альбома
    static func fetchAlbumTracks(albumId: Int, token: String) async -> [YMTrackItem] {
        guard let url = URL(string: apiBase + "/albums/" + String(albumId) + "/with-tracks") else { return [] }
        var req = URLRequest(url: url)
        if !token.isEmpty {
            req.setValue("OAuth " + token, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Response: Decodable {
                struct Result: Decodable {
                    let volumes: [[YMTrackItem]]?
                }
                let result: Result?
            }
            let resp = try JSONDecoder().decode(Response.self, from: data)
            let volumes = resp.result?.volumes ?? []
            return playable(volumes.flatMap { $0 })
        } catch {
            return []
        }
    }

    func getAlbumTracks(albumId: Int) async throws -> [YMTrackItem] {
        let generation = accountGeneration
        guard await ensureValidCredentials(), generation == accountGeneration else { throw URLError(.userAuthenticationRequired) }
        let items = await Self.fetchAlbumTracks(albumId: albumId, token: token)
        guard generation == accountGeneration, !Task.isCancelled else { throw CancellationError() }
        return items
    }

    /// Свежие треки («Топ-100 премьер») — зафиксированы на день до полуночи 00:00 (при наступлении полуночи обновляются).
    func getNewTracks(limit: Int = 100, force: Bool = false) async -> [YMTrackItem] {
        let generation = accountGeneration
        if !force, isDailyPremiereCacheValid {
            return Array(newTracksCache.prefix(limit))
        }

        // Fallback: проверка UserDefaults
        if !force,
           let data = UserDefaults.standard.data(forKey: Self.keyPremiereTracks),
           let savedDate = UserDefaults.standard.object(forKey: Self.keyPremiereDate) as? Date,
           Calendar.current.isDateInToday(savedDate),
           let savedTracks = try? JSONDecoder().decode([YMTrackItem].self, from: data),
           !savedTracks.isEmpty {
            self.newTracksCache = savedTracks
            self.newTracksCacheAt = savedDate
            return Array(savedTracks.prefix(limit))
        }

        let albums = (try? await getNewAlbums(force: force)) ?? []
        guard accountGeneration == generation, !Task.isCancelled else { return [] }
        let albumsToFetch = Array(albums.prefix(70))
        let currentToken = self.token
        var albumTracksMap: [Int: [YMTrackItem]] = [:]

        await withTaskGroup(of: (Int, [YMTrackItem]).self) { group in
            for album in albumsToFetch {
                group.addTask {
                    let tracks = await Self.fetchAlbumTracks(albumId: album.id, token: currentToken)
                    return (album.id, tracks)
                }
            }
            for await (albumId, tracks) in group {
                albumTracksMap[albumId] = tracks
            }
        }

        var out: [YMTrackItem] = []
        var seen = Set<String>()

        // 1. По 1-2 главных трека из каждого свежего релиза
        for album in albumsToFetch {
            guard let tracks = albumTracksMap[album.id] else { continue }
            for item in tracks.prefix(2) {
                if seen.insert(item.id).inserted {
                    out.append(item)
                    if out.count >= limit { break }
                }
            }
            if out.count >= limit { break }
        }

        // 2. Если треков меньше лимита (100), добираем остальные треки из этих же релизов
        if out.count < limit {
            for album in albumsToFetch {
                guard let tracks = albumTracksMap[album.id] else { continue }
                for item in tracks.dropFirst(2) {
                    if seen.insert(item.id).inserted {
                        out.append(item)
                        if out.count >= limit { break }
                    }
                }
                if out.count >= limit { break }
            }
        }

        // 3. Бэкфилл из чарта/каталога при необходимости
        if out.count < limit {
            let chartFallback = (try? await getChart(force: false)) ?? []
            for item in chartFallback {
                if seen.insert(item.id).inserted {
                    out.append(item)
                    if out.count >= limit { break }
                }
            }
        }

        if !out.isEmpty {
            let finalTop = Array(out.prefix(limit))
            guard accountGeneration == generation, !Task.isCancelled else { return [] }
            saveDailyPremiereCache(finalTop)
            return finalTop
        }
        return []
    }

    // MARK: - Радиостанции / «Моя волна» под настроение

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
        StationOption(id: "electronic", title: "Электроника", subtitle: "Клубный настрой", stationId: "genre:electronics", gradient: ["#FDE68A", "#EA580C"], icon: "waveform.path.ecg"),
        StationOption(id: "rock", title: "Рок", subtitle: "Гитары и драйв", stationId: "genre:rock", gradient: ["#F97316", "#450A0A"], icon: "guitars.fill"),
        StationOption(id: "party", title: "Вечеринка", subtitle: "Танцевальное", stationId: "activity:party", gradient: ["#FBBF24", "#9A3412"], icon: "party.popper.fill"),
        StationOption(id: "road", title: "В дорогу", subtitle: "Ритм для движения вперёд", stationId: "activity:driving", gradient: ["#E8EDF2", "#8A94A6"], icon: "car.fill"),
        StationOption(id: "dreamy", title: "Время помечтать", subtitle: "Воздушное и атмосферное", stationId: "mood:dreamy", gradient: ["#EAF6FF", "#93A9C7"], icon: "cloud.fill"),
        StationOption(id: "discover", title: "Незнакомое", subtitle: "Новые имена и открытия", stationId: "user:onyourwave", gradient: ["#00F2FE", "#4FACFE"], icon: "sparkles"),
        StationOption(id: "recap", title: "Итоги", subtitle: "Личный итог: что вы слушали", stationId: "app:recap", gradient: ["#F4E9FF", "#B79CE0"], icon: "sparkles")
    ]

    /// Станция текущего настроения волны.
    var waveMoodStation: StationOption {
        Self.rotorStations.first { $0.stationId == waveMoodStationId } ?? Self.rotorStations[0]
    }

    /// Подбор подходящих станций Яндекс Музыки по 6-мерному вектору звука (вайбу)
    func vibeStations(for vector: TrackVector) -> [String] {
        var stations: [String] = []

        // 1. По энергии и танцевальности
        if vector.energy > 0.70 && vector.danceability > 0.60 {
            stations.append("activity:party")
            stations.append("genre:electronics")
            stations.append("activity:workout")
        } else if vector.energy > 0.65 {
            stations.append("genre:rock")
            stations.append("activity:workout")
        }

        // 2. По темпу и динамике
        if vector.tempo > 0.65 && vector.energy > 0.50 {
            stations.append("genre:pop")
            stations.append("genre:rap")
            stations.append("activity:driving")
        }

        // 3. По спокойствию и акустичности
        if vector.energy < 0.45 && vector.acousticness > 0.40 {
            stations.append("mood:calm")
            stations.append("mood:dreamy")
        }

        // 4. По меланхолии / минору (низкий valence)
        if vector.valence < 0.35 && vector.energy < 0.55 {
            stations.append("mood:dreamy")
            stations.append("mood:calm")
        }

        if stations.isEmpty {
            stations = ["user:onyourwave", "genre:pop", "activity:driving"]
        }

        return stations
    }

    private var waveServerSettings: [String: String] {
        let settings = WaveSettingsStore.shared
        return ["diversity": settings.diversity.rotorValue,
                "language": settings.language.rotorValue, "moodEnergy": settings.moodEnergy.rotorValue]
    }

    /// Start/reconfigure explicitly; normal refill never starts another session.
    func startYandexWave(stationId: String, seedID: String? = nil) async -> [YMTrackItem] {
        let requestID = UUID(); trackStationRequestID = requestID
        let account = accountGeneration
        let playback = PlayerCore.shared.playbackRequestID
        let settings = waveServerSettings
        guard isUserLoggedIn else { return [] }
        do {
            let history = Array(recentYmIDs.prefix(Self.noRepeatWindow).reversed())
            let items = try await waveSession.start(station: stationId, settings: settings,
                history: history, seedTrack: seedID, canCommit: { [weak self] in
                    guard let self else { return false }
                    return self.accountGeneration == account && self.trackStationRequestID == requestID &&
                        PlayerCore.shared.playbackRequestID == playback
                })
            guard accountGeneration == account, trackStationRequestID == requestID, !Task.isCancelled else { return [] }
            activeStationId = stationId; rotorSessionID = UUID(); waveError = nil
            appliedWaveSettings = settings
            return items
        } catch {
            guard accountGeneration == account, trackStationRequestID == requestID else { return [] }
            if !(error is CancellationError) {
                if case YandexWaveSession<YMTrackItem>.Failure.unsupportedSetting = error {
                    waveError = "Яндекс не поддерживает выбранную настройку. Текущая волна сохранена."
                } else { waveError = "Не удалось обновить волну. Текущая очередь сохранена." }
                SonivoDiagnostics.log("Session startup failed: \(String(describing: error))", tag: "WAVE")
            }
            return []
        }
    }

    func startYandexTrackStation(seedID: String, target: Int) async -> [Track] {
        guard !seedID.isEmpty, target > 0 else { return [] }
        return await startYandexWave(stationId: "track:\(seedID)", seedID: seedID).map { convertToTrack($0) }
    }

    func refillYandexWave() async -> [YMTrackItem] {
        guard activeStationId != nil, isUserLoggedIn else { return [] }
        let session = rotorSessionID
        do {
            let history = PlayerCore.shared.queue.compactMap { Self.ymId(fromFileName: $0.fileName) }
            let items = try await waveSession.next(excluding: history)
            guard rotorSessionID == session, !Task.isCancelled else { return [] }
            if items.isEmpty && waveSession.requiresRestart { return await renewExpiredWave(session: session) }
            waveError = items.isEmpty ? "Ожидаем новые треки от Яндекса." : nil
            return items
        } catch {
            guard rotorSessionID == session else { return [] }
            if waveSession.requiresRestart { return await renewExpiredWave(session: session) }
            waveError = "Не удалось продолжить волну. Попробуйте снова."
            SonivoDiagnostics.log("Session refill failed: \(String(describing: error))", tag: "WAVE")
            return []
        }
    }
    private func renewExpiredWave(session: UUID) async -> [YMTrackItem] {
        guard let station = activeStationId, rotorSessionID == session else { return [] }
        let account = accountGeneration
        let history = PlayerCore.shared.queue.compactMap { Self.ymId(fromFileName: $0.fileName) }
        do {
            let items = try await waveSession.start(station: station, settings: appliedWaveSettings ?? waveServerSettings,
                history: history, canCommit: { [weak self] in
                    self?.accountGeneration == account && self?.rotorSessionID == session
                })
            guard rotorSessionID == session, accountGeneration == account else { return [] }
            waveError = nil
            SonivoDiagnostics.log("Expired server session renewed with queue history", tag: "WAVE")
            return items
        } catch {
            guard rotorSessionID == session, accountGeneration == account else { return [] }
            waveError = "Не удалось восстановить волну. Нажмите следующий, чтобы повторить запрос."
            return []
        }
    }
    func refillYandexTrackWave(target: Int = 25) async -> [Track] {
        guard activeStationId?.hasPrefix("track:") == true else { return [] }
        return await refillYandexWave().map { convertToTrack($0) }
    }
    func getStationTracks(stationId: String) async throws -> [YMTrackItem] {
        await startYandexWave(stationId: stationId)
    }
    func buildWaveQueue(stationId: String = "user:onyourwave", target: Int = 45) async -> [YMTrackItem] {
        // target is a prefetch hint, not permission to restart seven times or drop a batch tail.
        await startYandexWave(stationId: stationId)
    }

    /// Подборка на основе того, что пользователь реально слушает.
    func personalPicks(limit: Int, excluding: Set<String> = []) async -> [YMTrackItem] {
        let generation = accountGeneration
        guard limit > 0 else { return [] }
        var used = excluding
        var out: [YMTrackItem] = []

        for artist in topArtists.shuffled().prefix(8) {
            if out.count >= limit { break }
            let found = await searchAll(query: artist).tracks
            guard accountGeneration == generation, !Task.isCancelled else { return [] }
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
            guard accountGeneration == generation, !Task.isCancelled else { return [] }
            for item in chart.shuffled() {
                if out.count >= limit { break }
                if used.contains(item.id) { continue }
                used.insert(item.id)
                out.append(item)
            }
        }

        return out
    }

    /// «Итоги» — персональный рекап в духе Spotify Wrapped: собирает треки
    /// реально любимых исполнителей пользователя (лайки и дослушивания —
    /// вес из UserTasteEngine, частота прослушиваний — вес из памяти этого
    /// сервиса), а не случайную выдачу общего ротора. Явно дизлайкнутые
    /// исполнители исключаются.
    func buildRecapQueue(target: Int = 40) async -> [YMTrackItem] {
        let generation = accountGeneration
        let engineScores = UserTasteEngine.shared.artistScores
        var pool = Set(topArtists)
        pool.formUnion(engineScores.keys)
        var ranked = Array(pool)
        ranked.sort { a, b in
            let scoreA = engineScores[a, default: 0] + Double(artistCounts[a, default: 0])
            let scoreB = engineScores[b, default: 0] + Double(artistCounts[b, default: 0])
            if scoreA != scoreB { return scoreA > scoreB }
            return a < b
        }

        var out: [YMTrackItem] = []
        var seen = Set<String>()
        for artist in ranked.prefix(12) {
            if out.count >= target { break }
            if engineScores[artist, default: 0] < -5 { continue }
            let found = await searchAll(query: artist).tracks
            guard accountGeneration == generation, !Task.isCancelled else { return [] }
            for item in found.prefix(6) {
                if out.count >= target { break }
                if seen.contains(item.id) { continue }
                seen.insert(item.id)
                out.append(item)
            }
        }

        if out.count < target {
            let extra = await personalPicks(limit: target - out.count, excluding: seen)
            guard accountGeneration == generation, !Task.isCancelled else { return [] }
            out.append(contentsOf: extra)
        }

        if out.isEmpty {
            out = (try? await getChart()) ?? []
            guard accountGeneration == generation, !Task.isCancelled else { return [] }
        }

        return Array(out.prefix(target))
    }

    /// Compatibility lifecycle entry for non-radio callers; no fake radioStarted.
    func beginStationSession(_ stationId: String) {
        endStationSession()
    }
    func endStationSession(discardFeedback: Bool = false) {
        if !discardFeedback { PlayerCore.shared.finishWaveBeforeLeaving() }
        rotorSessionID = UUID(); trackStationRequestID = UUID()
        activeStationId = nil; waveError = nil; appliedWaveSettings = nil
        if discardFeedback { waveSession.reset() } else { waveSession.close() }
    }
    func reportTrackStarted(trackId: String) {
        waveSession.event(type: "trackStarted", trackID: trackId)
    }
    func reportSkip(trackId: String, totalPlayedSeconds: Double) {
        waveSession.event(type: "skip", trackID: trackId, seconds: totalPlayedSeconds)
    }
    func reportTrackFinished(trackId: String, totalPlayedSeconds: Double) {
        waveSession.event(type: "trackFinished", trackID: trackId, seconds: totalPlayedSeconds)
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
        guard isUserLoggedIn else { return }
        var keys = recentKeys.filter { $0 != key }
        keys.insert(key, at: 0)
        if keys.count > Self.memoryLimit { keys = Array(keys.prefix(Self.memoryLimit)) }
        recentKeys = keys
        totalPlays += 1

        let defaults = UserDefaults.standard
        defaults.set(keys, forKey: Self.keyRecent)
        defaults.set(totalPlays, forKey: Self.keyPlays)

        if let ymTrackId, !ymTrackId.isEmpty {
            var ymList = recentYmIDs.filter { $0 != ymTrackId }
            ymList.insert(ymTrackId, at: 0)
            if ymList.count > Self.memoryLimit { ymList = Array(ymList.prefix(Self.memoryLimit)) }
            recentYmIDs = ymList
            defaults.set(ymList, forKey: Self.keyRecentYm)
        }

        if let artist, !artist.isEmpty, artist != "Неизвестный исполнитель" {
            let parts = artist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for name in parts where !name.isEmpty {
                artistCounts[name, default: 0] += 1
            }
            defaults.set(artistCounts, forKey: Self.keyArtists)
        }


    }

    func isRecentlyPlayed(ymTrackId: String) -> Bool {
        if recentYmIDs.prefix(Self.noRepeatWindow).contains(ymTrackId) { return true }
        if recentKeys.prefix(Self.noRepeatWindow).contains(ymTrackId) { return true }
        if recentKeys.prefix(Self.noRepeatWindow).contains("ym_\(ymTrackId).mp3") { return true }
        if recentKeys.prefix(Self.noRepeatWindow).contains(Self.stableKey(for: ymTrackId)) { return true }
        return false
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
        recentYmIDs = []
        artistCounts = [:]
        totalPlays = 0
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.keyRecent)
        defaults.removeObject(forKey: Self.keyRecentYm)
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

    /// Modern signed endpoint used by current official Yandex Music clients to fetch true
    /// lossless/FLAC streams. The older /tracks/{id}/download-info list frequently omits FLAC
    /// entries entirely for third-party OAuth tokens, which is why Hi-Res Lossless selections
    /// were silently falling back to 320kbps mp3. This tries the real lossless master first.
    @ObservationIgnored private let losslessAssets = YandexLosslessAssetStore()
    private(set) var streamQualityLog: [String] = []
    private func recordStreamQuality(_ message: String) {
        streamQualityLog.append(message)
        if streamQualityLog.count > 40 { streamQualityLog.removeFirst(streamQualityLog.count - 40) }
        SonivoDiagnostics.log(message, tag: "STREAM_QUALITY")
    }
    func recordCachedQuality(accepted: Bool, facts: PlaybackQualityFacts) {
        let codec = (facts.codec ?? "unknown").filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(24)
        recordStreamQuality("cache accepted=\(accepted) codec=\(codec) bitrate=\(facts.bitrate ?? 0)")
    }
    func streamQualityReport() -> String {
        let player = PlayerCore.shared
        let facts = PlaybackQualityFacts(codec: player.currentCodec, bitrate: player.currentBitrate)
        return """
        Sonivo stream quality diagnostic
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
        Requested: \(player.audioQuality.label)
        Received: \(facts.detail ?? "unknown")
        Backend: \(player.usesStreamingBackend ? "stream" : "local/cache")
        API client: \(YandexStreamRequestContract.desktopClient)
        Transports: raw + decoded encraw. No credentials, decryption keys or stream URLs in this report.

        \(streamQualityLog.suffix(24).joined(separator: "\n"))
        """
    }
    private func getLosslessFileInfo(cleanId: String, quality: String = "lossless", transport: String = "raw") async -> StreamInfo? {
        let generation = accountGeneration
        let requestedCodecs = transport == "encraw" ? ["flac", "flac-mp4"] : YandexStreamRequestContract.codecs
        guard !cleanId.isEmpty,
              let request = YandexStreamRequestContract.request(base: Self.apiBase, trackID: cleanId,
                   timestamp: Int(Date().timeIntervalSince1970), quality: quality, codecs: requestedCodecs, transport: transport) else { return nil }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sessionData(for: request)
        } catch {
            if !Task.isCancelled {
                recordStreamQuality("get-file-info request failed; fallback required (authentication/network)")
            }
            return nil
        }
        if let http = response as? HTTPURLResponse {
            recordStreamQuality("get-file-info quality=\(quality) transport=\(transport) HTTP=\(http.statusCode)")
            guard http.statusCode == 200 else { return nil }
        }

        struct FileInfoResponse: Decodable {
            struct Result: Decodable {
                struct DownloadInfo: Decodable {
                    let codec: String?
                    let bitrate: Int?
                    let transport: String?
                    let quality: String?
                    let key: String?
                    let url: String?
                    let urls: [String]?
                }
                let downloadInfo: DownloadInfo?
            }
            let result: Result?
        }

        guard let parsed = try? JSONDecoder().decode(FileInfoResponse.self, from: data),
              let info = parsed.result?.downloadInfo,
              let codec = info.codec,
              let urlString = info.url ?? info.urls?.first,
              let streamURL = URL(string: urlString), streamURL.scheme == "https" else {
            recordStreamQuality("get-file-info missing or invalid downloadInfo; fallback required")
            return nil
        }
        guard accountGeneration == generation, !Task.isCancelled else { return nil }
        let safeCodec = codec.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(24)
        let safeQuality = (info.quality ?? "unknown").filter { $0.isLetter || $0 == "-" }.prefix(24)
        recordStreamQuality("get-file-info codec=\(safeCodec) bitrate=\(info.bitrate ?? 0) quality=\(safeQuality)")
        if info.transport == "raw" || (info.transport == nil && transport == "raw") {
            return StreamInfo(url: streamURL, bitrate: info.bitrate ?? 0, codec: codec)
        }
        guard info.transport == "encraw", ["flac", "flac-mp4"].contains(codec.lowercased()),
              let key = info.key else {
            recordStreamQuality("get-file-info encrypted/unknown transport not playable; fallback required")
            return nil
        }
        do {
            let decoded = try await losslessAssets.materialize(url: streamURL, keyHex: key, codec: codec,
                trackID: cleanId, account: generation, protectedURLs: {
                    await MainActor.run { PlayerCore.shared.protectedPlaybackURLs }
                })
            guard accountGeneration == generation else {
                await losslessAssets.discard(decoded); return nil
            }
            guard !Task.isCancelled else { return nil }
            recordStreamQuality("encraw decoded and native FLAC validated")
            return StreamInfo(url: decoded, bitrate: info.bitrate ?? 0, codec: codec)
        } catch {
            if !Task.isCancelled { recordStreamQuality("encraw decode/validation failed; fallback required") }
            return nil
        }
    }

    func getStreamInfo(for trackId: String, preferredQuality: AudioQuality = .auto, preferredBitrate: Int? = nil) async throws -> StreamInfo {
        let generation = accountGeneration
        let cleanId = trackId.replacingOccurrences(of: "ym_", with: "").replacingOccurrences(of: ".mp3", with: "")

        // The legacy /download-info endpoint stopped reliably returning FLAC entries for most
        // third-party OAuth tokens (Yandex now gates real Hi-Res/Lossless behind the signed
        // get-file-info endpoint). Try that first whenever lossless or automatic quality is
        // wanted, and only fall back to the legacy list below if this track truly has no
        // lossless master there.
        recordStreamQuality("resolve requested=\(preferredQuality.rawValue) track=\(cleanId.filter(\.isNumber).prefix(20))")
        var signedLossyFallback: StreamInfo?
        if preferredQuality == .hiResLossless || preferredQuality == .lossless || preferredQuality == .auto || preferredQuality == .hq {
            if let losslessInfo = await getLosslessFileInfo(cleanId: cleanId, quality: preferredQuality == .hq ? "hq" : "lossless") {
                guard accountGeneration == generation, !Task.isCancelled else { throw CancellationError() }
                SonivoDiagnostics.log("get-file-info delivered \(losslessInfo.codec) \(losslessInfo.bitrate)kbps for \(cleanId)", tag: "STREAM")
                if PlaybackQualityFacts(codec: losslessInfo.codec, bitrate: losslessInfo.bitrate).isLossless
                    || (preferredQuality == .hq && losslessInfo.bitrate >= 256) {
                    return losslessInfo
                }
                // Signed "lossless" requests can return AAC/MP3. Check legacy FLAC first,
                // but retain a playable answer if the legacy endpoint fails.
                signedLossyFallback = losslessInfo
            }
        }

        // Probe encrypted FLAC only after raw could not provide lossless. Do not download
        // encrypted AAC/MP3 merely to relabel it; retain the already playable raw fallback.
        if preferredQuality == .lossless || preferredQuality == .hiResLossless || preferredQuality == .auto {
            if let decoded = await getLosslessFileInfo(cleanId: cleanId, transport: "encraw") {
                guard accountGeneration == generation, !Task.isCancelled else { throw CancellationError() }
                if PlaybackQualityFacts(codec: decoded.codec, bitrate: decoded.bitrate).isLossless { return decoded }
            }
        }

        do {
            guard let downloadInfoListURL = URL(string: Self.apiBase + "/tracks/" + cleanId + "/download-info") else { throw URLError(.badURL) }
            let req = authorizedRequest(url: downloadInfoListURL)
            let (data, response) = try await sessionData(for: req)
            if let http = response as? HTTPURLResponse {
                recordStreamQuality("legacy download-info HTTP=\(http.statusCode)")
                guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            }

            struct DownloadInfoEntry: Codable {
                let codec: String
                let bitrateInKbps: Int
                let downloadInfoUrl: String
                let direct: Bool?
                let container: String?
            }
            struct DownloadInfoResponse: Codable {
                let result: [DownloadInfoEntry]?
            }

            let infoResp = try JSONDecoder().decode(DownloadInfoResponse.self, from: data)
            guard let list = infoResp.result, !list.isEmpty else {
                throw URLError(.cannotFindHost)
            }

            let variants = list.map { entry in
                let label = entry.codec.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(24)
                return "\(label):\(entry.bitrateInKbps)"
            }.joined(separator: ", ")
            recordStreamQuality("legacy offered=[\(variants)]")
            let best: DownloadInfoEntry
            switch preferredQuality {
            case .hiResLossless, .lossless:
                let flacs = list.filter { $0.codec.lowercased() == "flac" }
                if let bestFlac = flacs.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) {
                    best = bestFlac
                } else {
                    best = list.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list[0]
                }
            case .hq:
                let hqs = list.filter { $0.bitrateInKbps >= 256 }
                best = hqs.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list[0]
            case .economical:
                best = list.min(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list[0]
            case .auto:
                if let preferred = preferredBitrate {
                    best = list.min(by: { abs($0.bitrateInKbps - preferred) < abs($1.bitrateInKbps - preferred) }) ?? list[0]
                } else {
                    let flacs = list.filter { $0.codec.lowercased() == "flac" }
                    if let bestFlac = flacs.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) {
                        best = bestFlac
                    } else {
                        best = list.max(by: { $0.bitrateInKbps < $1.bitrateInKbps }) ?? list[0]
                    }
                }
            }

            guard accountGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            if let fallback = signedLossyFallback,
               !PlaybackQualityFacts(codec: best.codec, bitrate: best.bitrateInKbps).isLossless,
               PlaybackQualityFacts(codec: fallback.codec, bitrate: fallback.bitrate).isPreferred(
                    over: PlaybackQualityFacts(codec: best.codec, bitrate: best.bitrateInKbps)) {
                return fallback
            }
            if best.direct == true {
                guard let direct = URL(string: best.downloadInfoUrl), direct.scheme == "https" else { throw URLError(.badURL) }
                recordStreamQuality("legacy direct selected=\(best.codec.filter { $0.isLetter || $0 == "-" }.prefix(24)):\(best.bitrateInKbps)")
                return StreamInfo(url: direct, bitrate: best.bitrateInKbps, codec: best.codec)
            }
            guard let xmlURL = URL(string: best.downloadInfoUrl) else { throw URLError(.badURL) }
            let (xmlData, _) = try await URLSession.shared.data(from: xmlURL)
            guard accountGeneration == generation, !Task.isCancelled else { throw CancellationError() }
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

            let getEndpoint = best.codec.lowercased() == "flac" ? "get-flac" : "get-mp3"
            let finalURLString = "https://" + host + "/" + getEndpoint + "/" + sign + "/" + ts + path
            guard let finalURL = URL(string: finalURLString) else { throw URLError(.badURL) }
            let selectedCodec = best.codec.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(24)
            recordStreamQuality("legacy selected=\(selectedCodec):\(best.bitrateInKbps)")
            return StreamInfo(url: finalURL, bitrate: best.bitrateInKbps, codec: best.codec)
        } catch {
            guard accountGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            if error is CancellationError { throw error }
            if let fallback = signedLossyFallback {
                recordStreamQuality("legacy failed; retained signed fallback bitrate=\(fallback.bitrate)")
                return fallback
            }
            throw error
        }
    }

    // MARK: - Convert YMTrackItem to App Track Model

    nonisolated func convertToTrack(_ ym: YMTrackItem) -> Track {
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

    // MARK: - Video Shots (Canvas Video from Yandex API)

    private var videoShotCache: [String: URL] = [:]

    /// Получение официального вертикального видеошота (Canvas Video 9:16) для трека из Yandex Music API
    func getVideoShotUrl(for trackId: String) async -> URL? {
        let generation = accountGeneration
        guard isUserLoggedIn, !Task.isCancelled else { return nil }
        let cleanId = trackId
            .replacingOccurrences(of: "ym_", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return nil }
        if let cached = videoShotCache[cleanId] { return cached }

        // 1. ПРИОРИТЕТ №1: Официальный вертикальный видеошот лейбла (backgroundVideoUri: 1080x1920)
        if let trackURL = URL(string: Self.apiBase + "/tracks/" + cleanId) {
            if let (data, _) = try? await sessionData(for: authorizedRequest(url: trackURL)) {
                guard !Task.isCancelled, accountGeneration == generation else { return nil }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = (json["result"] as? [[String: Any]])?.first ?? (json["result"] as? [String: Any]) {
                    var candidate: String? = nil
                    // Официальный вертикальный Canvas Video
                    if let bgUri = result["backgroundVideoUri"] as? String, !bgUri.isEmpty {
                        candidate = bgUri
                    } else if let s = result["videoShotUrl"] as? String, !s.isEmpty {
                        candidate = s
                    } else if let s = result["shotUrl"] as? String, !s.isEmpty {
                        candidate = s
                    } else if let s = result["canvasUrl"] as? String, !s.isEmpty {
                        candidate = s
                    }

                    if let candidate, let shotURL = URL(string: candidate.hasPrefix("http") ? candidate : "https://" + candidate) {
                        videoShotCache[cleanId] = shotURL
                        SonivoDiagnostics.log("Official VideoShot (backgroundVideoUri) found for \(cleanId): \(shotURL.absoluteString)", tag: "VIDEOSHOT")
                        return shotURL
                    }
                }
            }
        }

        guard !Task.isCancelled, accountGeneration == generation else { return nil }
        // 2. Резервный запрос в /tracks/{id}/supplement
        if let suppURL = URL(string: Self.apiBase + "/tracks/" + cleanId + "/supplement") {
            if let (data, _) = try? await sessionData(for: authorizedRequest(url: suppURL)) {
                guard !Task.isCancelled, accountGeneration == generation else { return nil }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any] {
                    var candidate: String? = nil
                    if let bg = result["backgroundVideoUri"] as? String, !bg.isEmpty { candidate = bg }
                    else if let s = result["videoShotUrl"] as? String, !s.isEmpty { candidate = s }
                    else if let s = result["shotUrl"] as? String, !s.isEmpty { candidate = s }
                    else if let s = result["canvasUrl"] as? String, !s.isEmpty { candidate = s }

                    if let candidate, let shotURL = URL(string: candidate.hasPrefix("http") ? candidate : "https://" + candidate) {
                        videoShotCache[cleanId] = shotURL
                        SonivoDiagnostics.log("VideoShot found in supplement for \(cleanId): \(shotURL.absoluteString)", tag: "VIDEOSHOT")
                        return shotURL
                    }
                }
            }
        }

        guard !Task.isCancelled, accountGeneration == generation else { return nil }
        // 3. Резервный запрос официального видео артиста через /artists/{id}/brief-info
        if let trackURL = URL(string: Self.apiBase + "/tracks/" + cleanId) {
            if let (data, _) = try? await sessionData(for: authorizedRequest(url: trackURL)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = (json["result"] as? [[String: Any]])?.first ?? (json["result"] as? [String: Any]),
               let artists = result["artists"] as? [[String: Any]],
               let firstArtist = artists.first,
               let artistId = firstArtist["id"] {
                let artistIdStr = "\(artistId)"
                if let artURL = URL(string: Self.apiBase + "/artists/" + artistIdStr + "/brief-info") {
                    if let (artData, _) = try? await sessionData(for: authorizedRequest(url: artURL)),
                       let artJson = try? JSONSerialization.jsonObject(with: artData) as? [String: Any],
                       let artRes = artJson["result"] as? [String: Any],
                       let artistObj = artRes["artist"] as? [String: Any] {
                        guard !Task.isCancelled, accountGeneration == generation else { return nil }
                        var candidate: String? = nil
                        if let bg = artistObj["backgroundVideoUrl"] as? String, !bg.isEmpty { candidate = bg }
                        else if let bg = artistObj["videoUrl"] as? String, !bg.isEmpty { candidate = bg }
                        else if let bg = artistObj["headerVideoUrl"] as? String, !bg.isEmpty { candidate = bg }

                        if let candidate, let shotURL = URL(string: candidate.hasPrefix("http") ? candidate : "https://" + candidate) {
                            videoShotCache[cleanId] = shotURL
                            SonivoDiagnostics.log("VideoShot found from artist brief-info for \(cleanId): \(shotURL.absoluteString)", tag: "VIDEOSHOT")
                            return shotURL
                        }
                    }
                }
            }
        }

        return nil
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
    nonisolated private static func stableID(from string: String) -> UUID {
        let bytes = Array(Insecure.MD5.hash(data: Data(string.utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Account, Profile & Cloud Sync

    private func profile(for candidateToken: String) async -> YMUserProfile? {
        guard !candidateToken.isEmpty,
              let url = URL(string: Self.apiBase + "/account/status") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("OAuth " + candidateToken, forHTTPHeaderField: "Authorization")
        req.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }

            struct AccountData: Decodable {
                let uid: Int?
                let login: String?
                let fullName: String?
                let displayName: String?
                let default_avatar_id: String?
            }
            struct PlusData: Decodable {
                let hasPlus: Bool?
            }
            struct StatusResult: Decodable {
                let account: AccountData?
                let plus: PlusData?
                let default_avatar_id: String?
            }
            struct ResponseWrapper: Decodable {
                let result: StatusResult?
            }

            let decoded = try JSONDecoder().decode(ResponseWrapper.self, from: data)
            guard let acc = decoded.result?.account, let uid = acc.uid, uid > 0 else { return nil }

            let avatarId = acc.default_avatar_id ?? decoded.result?.default_avatar_id
            let avatarUrl = avatarId.map { "https://avatars.yandex.net/get-yapic/\($0)/islands-200" }
            let hasPlus = decoded.result?.plus?.hasPlus ?? false

            let profile = YMUserProfile(
                uid: uid,
                login: acc.login ?? "user\(uid)",
                displayName: acc.displayName ?? acc.fullName ?? acc.login,
                fullName: acc.fullName,
                avatarUrl: avatarUrl,
                hasPlus: hasPlus
            )

            return profile
        } catch {
            return nil
        }
    }

    func fetchTracksBatch(ids: [String]) async -> [YMTrackItem] {
        guard !ids.isEmpty else { return [] }
        guard let url = URL(string: Self.apiBase + "/tracks") else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let activeToken = token
        req.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
        req.setValue("YandexMusic/2024.1", forHTTPHeaderField: "User-Agent")
        req.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")

        let body = "track-ids=" + ids.joined(separator: ",")
        req.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await sessionData(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            struct ResponseWrapper: Decodable {
                let result: [YMTrackItem]?
            }
            let decoded = try JSONDecoder().decode(ResponseWrapper.self, from: data)
            return decoded.result ?? []
        } catch {
            return []
        }
    }

    private func fetchUserLikes(uid: Int, limit: Int = 2000) async -> [YMTrackItem]? {
        guard let url = URL(string: Self.apiBase + "/users/\(uid)/likes/tracks") else { return nil }
        let req = authorizedRequest(url: url)

        do {
            let (data, response) = try await sessionData(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }

            struct LikeTrackItem: Decodable {
                let id: String?
            }
            struct LibraryWrapper: Decodable {
                let tracks: [LikeTrackItem]?
            }
            struct ResultWrapper: Decodable {
                let library: LibraryWrapper?
            }
            struct ResponseWrapper: Decodable {
                let result: ResultWrapper?
            }

            let decoded = try JSONDecoder().decode(ResponseWrapper.self, from: data)
            guard let liked = decoded.result?.library?.tracks else { return nil }
            let rawIds = liked.compactMap { $0.id }
            guard rawIds.count <= limit else { return nil }
            let prefixIds = rawIds
            guard !prefixIds.isEmpty else { return [] }
            let generation = accountGeneration
            var tracks: [YMTrackItem] = []
            for start in stride(from: 0, to: prefixIds.count, by: 200) {
                let ids = Array(prefixIds[start..<min(start + 200, prefixIds.count)])
                let batch = await fetchTracksBatch(ids: ids)
                guard accountGeneration == generation, !Task.isCancelled,
                      Set(batch.map(\.id)) == Set(ids) else { return nil }
                tracks.append(contentsOf: batch)
            }
            return tracks
        } catch {
            return nil
        }
    }

    func fetchAccountStatus() async -> YMUserProfile? {
        guard await ensureValidCredentials() else { return nil }
        let generation = accountGeneration
        let activeToken = token
        guard let profile = await profile(for: activeToken),
              !Task.isCancelled, accountGeneration == generation,
              credential?.uid == profile.uid else { return nil }
        installProfile(profile)
        return profile
    }

    private func installProfile(_ profile: YMUserProfile) {
        currentUser = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "ym.user_profile")
        }
    }

    func syncAccountData() async {
        guard !Task.isCancelled else { return }
        let generation = accountGeneration
        if let task = accountSyncTask, accountSyncGeneration == generation { await task.value; return }
        accountSyncTask?.cancel()
        let request = UUID(); accountSyncRequestID = request; accountSyncGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAccountSync(generation: generation)
        }
        accountSyncTask = task; await task.value
        if accountSyncRequestID == request { accountSyncTask = nil; accountSyncGeneration = nil }
    }
    private func performAccountSync(generation: UUID) async {
        guard accountGeneration == generation, !Task.isCancelled else { return }
        guard let profile = await fetchAccountStatus(),
              accountGeneration == generation, !Task.isCancelled else { return }
        guard let likedItems = await fetchUserLikes(uid: profile.uid, limit: 2000),
              accountGeneration == generation, !Task.isCancelled else {
            if accountGeneration == generation { accountSyncMessage = "Не удалось полностью обновить избранное (до 2000 треков). Сохранённые данные не изменены." }
            return
        }
        let converted = await Task.detached(priority: .utility) { likedItems.map { self.convertToTrack($0) } }.value
        guard accountGeneration == generation, !Task.isCancelled else { return }
        LibraryStore.shared.setFavoritesFromCloud(converted)
        let playlistsOK = await syncPersonalPlaylists(uid: profile.uid, generation: generation)
        guard accountGeneration == generation, !Task.isCancelled else { return }
        accountSyncMessage = playlistsOK ? nil : "Избранное обновлено. Плейлисты не удалось загрузить полностью (до 50 плейлистов, до 2000 треков в каждом). Повторите синхронизацию позже."
    }

    func loginWithToken(_ newToken: String) async -> Bool {
        await loginWithOAuthToken(YandexOAuthToken(access_token: newToken.trimmingCharacters(in: .whitespacesAndNewlines), refresh_token: nil, expires_in: nil, token_type: nil))
    }

    func loginWithOAuthToken(_ result: YandexOAuthToken) async -> Bool {
        let attempt = UUID()
        loginAttemptID = attempt
        let generation = accountGeneration
        guard let profile = await profile(for: result.access_token),
              !Task.isCancelled, loginAttemptID == attempt,
              accountGeneration == generation else { return false }
        let candidate = YandexCredential(uid: profile.uid, token: result)
        guard YandexCredentialStore.save(candidate) else { return false }
        // No suspension between validating, persisting and replacing the session.
        let changedAccount = credential?.uid != profile.uid
        accountGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        if changedAccount { resetPersonalState(); LibraryStore.shared.clearYandexAccountData(); stopOldYandexPlayback() }
        credential = candidate
        token = candidate.accessToken
        isAuthorized = true
        installProfile(profile)
        let installedGeneration = accountGeneration
        Task { guard accountGeneration == installedGeneration else { return }; await syncAccountData() }
        return true
    }

    private func ensureValidCredentials() async -> Bool {
        guard let credential, !token.isEmpty else { return false }
        guard credential.needsRefresh() else { return true }
        if let refreshTask { return await refreshTask.value }
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            logout()
            return false
        }
        let generation = accountGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            do {
                let refreshed = try await YandexDeviceAuthClient.shared.refresh(refreshToken)
                guard let profile = await self.profile(for: refreshed.access_token),
                      profile.uid == credential.uid,
                      !Task.isCancelled, self.accountGeneration == generation else { return false }
                let updated = YandexCredential(uid: credential.uid, token: refreshed, previousRefreshToken: refreshToken)
                guard YandexCredentialStore.save(updated) else { return false }
                self.credential = updated
                self.token = updated.accessToken
                self.installProfile(profile)
                return true
            } catch {
                if !Task.isCancelled, self.accountGeneration == generation,
                   error as? YandexAuthError == .rejectedToken { self.logout() }
                return false
            }
        }
        refreshTask = task
        let ok = await task.value
        if accountGeneration == generation { refreshTask = nil }
        return ok && accountGeneration == generation && !Task.isCancelled
    }

    // All mutable account API responses are discarded after logout/account replacement.
    func sessionData(for original: URLRequest) async throws -> (Data, URLResponse) {
        let generation = accountGeneration
        guard await ensureValidCredentials(), accountGeneration == generation else { throw URLError(.userAuthenticationRequired) }
        try Task.checkCancellation()
        let activeToken = token
        var request = original
        request.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        let result = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard accountGeneration == generation else { throw CancellationError() }
        if (result.1 as? HTTPURLResponse)?.statusCode == 401, token == activeToken {
            // File-info 401 can mean an invalid client/signature, not an invalid account token.
            // The authenticated legacy request still validates the token before any fallback plays.
            if original.url?.path == "/get-file-info" { return result }
            logout(); throw URLError(.userAuthenticationRequired)
        }
        return result
    }

    func likeTrackOnServer(trackId: String) async {
        guard let uid = currentUser?.uid else { return }
        guard let url = URL(string: Self.apiBase + "/users/\(uid)/likes/tracks/add-multiple") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let activeToken = token
        req.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
        req.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        req.httpBody = "track-ids=\(trackId)".data(using: .utf8)

        _ = try? await sessionData(for: req)
    }

    func unlikeTrackOnServer(trackId: String) async {
        guard let uid = currentUser?.uid else { return }
        guard let url = URL(string: Self.apiBase + "/users/\(uid)/likes/tracks/remove") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let activeToken = token
        req.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("ru", forHTTPHeaderField: "Accept-Language")
        req.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        req.httpBody = "track-ids=\(trackId)".data(using: .utf8)

        _ = try? await sessionData(for: req)
    }

    private func resetPersonalState() {
        streamQualityLog.removeAll()
        accountSyncTask?.cancel(); accountSyncTask = nil; accountSyncGeneration = nil; accountSyncRequestID = UUID()
        waveSession.reset() // Discard the previous account's pending events before closing.
        endStationSession()
        trackStationRequestID = UUID()
        recentKeys = []
        recentYmIDs = []
        artistCounts = [:]
        totalPlays = 0
        videoShotCache = [:]
        chartCache = []; chartCacheAt = nil
        newAlbumsCache = []; newAlbumsCacheAt = nil
        newTracksCache = []; newTracksCacheAt = nil
        artistCache = [:]; artistTracksCache = [:]
        waveMoodStationId = "user:onyourwave"
        accountSyncMessage = nil
        for key in [Self.keyRecent, Self.keyRecentYm, Self.keyArtists, Self.keyPlays,
                    Self.keyPremiereTracks, Self.keyPremiereDate, "ym.waveMood", "sonivo_recent_searches"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func stopOldYandexPlayback() {
        let player = PlayerCore.shared
        if let track = player.currentTrack, Self.isPersonalYandexTrack(track) {
            player.stopAndClear()
        }
        player.queue.removeAll { Self.isPersonalYandexTrack($0) }
    }

    static func isPersonalYandexTrack(_ track: Track) -> Bool {
        track.isStream && ymId(fromFileName: track.fileName) != nil
    }

    func logout() {
        accountGeneration = UUID()
        loginAttemptID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        token = ""
        isAuthorized = false
        credential = nil
        currentUser = nil
        YandexCredentialStore.remove()
        UserDefaults.standard.removeObject(forKey: "ym.token")
        UserDefaults.standard.removeObject(forKey: "ym.user_profile")
        resetPersonalState()
        LibraryStore.shared.clearYandexAccountData()
        stopOldYandexPlayback()
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let activeToken = token
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
