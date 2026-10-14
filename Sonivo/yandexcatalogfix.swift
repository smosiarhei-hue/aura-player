import Foundation

// MARK: - Catalog compatibility types

typealias YMArtistBrief = YandexMusicService.YMArtistItem.YMArtistBrief

private struct YMCatalogArtistCover: Decodable {
    let uri: String?
}

private struct YMCatalogSearchArtist: Decodable {
    struct Ratings: Decodable {
        let month: Int?
        let week: Int?
        let day: Int?
    }
    let id: String?
    let name: String?
    let coverUri: String?
    let cover: YMCatalogArtistCover?
    let ratings: Ratings?
    let likesCount: Int?
    enum CodingKeys: String, CodingKey { case id, name, coverUri, cover, ratings, likesCount }
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        id=(try? c.decode(String.self,forKey: .id)) ?? (try? c.decode(Int.self,forKey: .id)).map(String.init)
        name=try c.decodeIfPresent(String.self,forKey: .name)
        coverUri=try c.decodeIfPresent(String.self,forKey: .coverUri)
        cover=try c.decodeIfPresent(YMCatalogArtistCover.self,forKey: .cover)
        ratings=try c.decodeIfPresent(Ratings.self,forKey: .ratings)
        likesCount=try c.decodeIfPresent(Int.self,forKey: .likesCount)
    }
}
private struct YMCatalogSearchResponse: Decodable {
    struct Result: Decodable {
        struct Block<Item: Decodable>: Decodable {
            let results: [Item]?
            let total: Int?
            let perPage: Int?
        }
        struct BestBlock: Decodable {
            let type: String?
            let track: YandexMusicService.YMTrackItem?
            let artist: YMCatalogSearchArtist?
            let album: YandexMusicService.YMAlbumItem?
            enum CodingKeys: String, CodingKey { case type, result }
            init(from decoder: Decoder) throws {
                let c=try decoder.container(keyedBy: CodingKeys.self)
                type=try c.decodeIfPresent(String.self,forKey: .type)
                track=type == "track" ? (try? c.decode(YandexMusicService.YMTrackItem.self,forKey: .result)) : nil
                artist=type == "artist" ? (try? c.decode(YMCatalogSearchArtist.self,forKey: .result)) : nil
                album=type == "album" ? (try? c.decode(YandexMusicService.YMAlbumItem.self,forKey: .result)) : nil
            }
        }
        let best: BestBlock?
        let tracks: Block<YandexMusicService.YMTrackItem>?
        let artists: Block<YMCatalogSearchArtist>?
        let albums: Block<YandexMusicService.YMAlbumItem>?
        let misspellCorrected: Bool?
        let misspellResult: String?
    }
    let result: Result?
}

private struct YMCatalogArtistDetails: Decodable {
    struct Counts: Decodable {
        let tracks: Int?
        let directAlbums: Int?
    }
    let id: Int?
    let name: String?
    let coverUri: String?
    let cover: YMCatalogArtistCover?
    let genres: [String]?
    let counts: Counts?
}

private struct YMCatalogSimilarArtist: Decodable {
    let id: Int?
    let name: String?
    let coverUri: String?
    let cover: YMCatalogArtistCover?
}

private struct YMCatalogArtistResponse: Decodable {
    struct Result: Decodable {
        let artist: YMCatalogArtistDetails?
        let popularTracks: [YandexMusicService.YMTrackItem]?
        let albums: [YandexMusicService.YMAlbumItem]?
        let similarArtists: [YMCatalogSimilarArtist]?
    }
    let result: Result?
}

// MARK: - Safe global catalog decoding

extension YandexMusicService {
    /// Curator-only track search: no artist/album expansion, four callers at most.
    func searchCuratorTracks(query: String) async throws -> [YMTrackItem] {
        guard isUserLoggedIn, !Task.isCancelled else { return [] }
        guard var components = URLComponents(string: Self.apiBase + "/search") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name:"text",value:String(query.prefix(600))),
            URLQueryItem(name:"type",value:"track"),URLQueryItem(name:"page",value:"0"),URLQueryItem(name:"nocorrect",value:"true")]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = catalogRequest(url:url); request.timeoutInterval = 15
        let (data,response) = try await sessionData(for:request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard data.count <= 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let decoded = try JSONDecoder().decode(YMCatalogSearchResponse.self,from:data)
        return Self.playable(decoded.result?.tracks?.results ?? [])
    }

    func searchAllFixed(query: String) async -> GlobalSearchResults {
        (try? await searchCatalog(query: query)) ?? GlobalSearchResults()
    }

    /// Preserve native relevance. Do not rank artist-prefix matches above a requested song.
    func searchCatalog(query: String, kind: YandexSearchKind = .all, page: Int = 0,
                       noCorrect: Bool = false) async throws -> GlobalSearchResults {
        let clean=YandexSearchContract.clean(query)
        guard !clean.isEmpty else { return GlobalSearchResults() }
        try Task.checkCancellation()
        let generation=accountGeneration
        let url=try YandexSearchContract.url(base: Self.apiBase,text: clean,kind: kind,page: page,noCorrect: noCorrect)
        var request=catalogRequest(url: url); request.timeoutInterval=15
        let (data,response)=try await sessionData(for: request)
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
        try YandexSearchContract.validate(response,bytes: data.count)
        guard let result=try JSONDecoder().decode(YMCatalogSearchResponse.self,from: data).result else {
            throw YandexSearchError.invalidResponse
        }
        var tracks=Self.playable(result.tracks?.results ?? [])
        var rawArtists=result.artists?.results ?? []
        var albums=(result.albums?.results ?? []).filter { $0.id != 0 }
        // best.result may be returned separately from a category block.
        if page == 0 {
            if let track=result.best?.track,track.available != false,!tracks.contains(where: { $0.id == track.id }) { tracks.insert(track,at: 0) }
            if let artist=result.best?.artist,!rawArtists.contains(where: { $0.id == artist.id }) { rawArtists.insert(artist,at: 0) }
            if let album=result.best?.album,album.id != 0,!albums.contains(where: { $0.id == album.id }) { albums.insert(album,at: 0) }
        }
        var seenArtists=Set<String>(),seenAlbums=Set<Int>()
        let artists=rawArtists.compactMap { raw -> YMArtistBrief? in
            guard let id=raw.id,!id.isEmpty,let name=raw.name,!name.isEmpty,seenArtists.insert(id).inserted else { return nil }
            return YMArtistBrief(id: id,name: name,coverUri: raw.coverUri ?? raw.cover?.uri)
        }
        albums=albums.filter { seenAlbums.insert($0.id).inserted }
        let next=((kind == .all || kind == .track) && YandexSearchContract.hasNext(total: result.tracks?.total,perPage: result.tracks?.perPage,page: page))
            || ((kind == .all || kind == .artist) && YandexSearchContract.hasNext(total: result.artists?.total,perPage: result.artists?.perPage,page: page))
            || ((kind == .all || kind == .album) && YandexSearchContract.hasNext(total: result.albums?.total,perPage: result.albums?.perPage,page: page))
        return GlobalSearchResults(tracks: kind == .all || kind == .track ? tracks : [],
                                   artists: kind == .all || kind == .artist ? artists : [],
                                   albums: kind == .all || kind == .album ? albums : [],suggestions: [],
                                   correctedQuery: result.misspellCorrected == true ? result.misspellResult : nil,
                                   bestType: result.best?.type,hasNextPage: next)
    }

    func getArtistFixed(artistId: String) async throws -> YMArtistItem {
        if let brief = await loadArtistBrief(artistId: artistId) {
            var result = brief

            if result.popularTracks.isEmpty {
                result.popularTracks = (try? await getArtistTracks(
                    artistId: artistId,
                    page: 0,
                    pageSize: 50
                )) ?? []
            }

            if result.albums.isEmpty {
                result.albums = await albumsFromTracks(result.popularTracks)
            }

            return result
        }

        let tracks = (try? await getArtistTracks(
            artistId: artistId,
            page: 0,
            pageSize: 50
        )) ?? []

        let matchingArtist = tracks
            .flatMap { $0.artists ?? [] }
            .first { artist in
                guard let id = artist.id else { return false }
                return String(id) == artistId
            }

        let firstNamedArtist = tracks
            .flatMap { $0.artists ?? [] }
            .first { !($0.name ?? "").isEmpty }

        let name = matchingArtist?.name ?? firstNamedArtist?.name ?? "Артист"
        let coverUri = tracks.first?.coverUri ?? tracks.first?.albums?.first?.coverUri
        let albums = await albumsFromTracks(tracks)

        return YMArtistItem(
            id: artistId,
            name: name,
            coverUri: coverUri,
            genres: [],
            counts: YMArtistItem.ArtistCounts(
                tracks: tracks.count,
                directAlbums: albums.count
            ),
            popularTracks: tracks,
            albums: albums,
            similarArtists: []
        )
    }

    private func loadArtistBrief(artistId: String) async -> YMArtistItem? {
        guard var components = URLComponents(string: Self.apiBase + "/artists/" + artistId + "/brief-info") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "popularTracks", value: "true"),
            URLQueryItem(name: "discography", value: "true"),
            URLQueryItem(name: "similarArtists", value: "true")
        ]
        guard let url = components.url,
              let pair = try? await sessionData(for: catalogRequest(url: url)),
              let decoded = try? JSONDecoder().decode(YMCatalogArtistResponse.self, from: pair.0),
              let raw = decoded.result?.artist,
              let id = raw.id,
              let name = raw.name else {
            return nil
        }

        let popular = Self.playable(decoded.result?.popularTracks ?? [])
        let albums = (decoded.result?.albums ?? []).filter { $0.id != 0 }
        let similar = (decoded.result?.similarArtists ?? []).compactMap { raw -> YMArtistBrief? in
            guard let id = raw.id, let name = raw.name else { return nil }
            return YMArtistBrief(
                id: String(id),
                name: name,
                coverUri: raw.coverUri ?? raw.cover?.uri
            )
        }

        return YMArtistItem(
            id: String(id),
            name: name,
            coverUri: raw.coverUri ?? raw.cover?.uri,
            genres: raw.genres ?? [],
            counts: YMArtistItem.ArtistCounts(
                tracks: raw.counts?.tracks,
                directAlbums: raw.counts?.directAlbums
            ),
            popularTracks: popular,
            albums: albums,
            similarArtists: similar
        )
    }

    private func albumsFromTracks(_ tracks: [YMTrackItem]) async -> [YMAlbumItem] {
        var seen = Set<Int>()
        var ids: [Int] = []

        for track in tracks {
            for album in track.albums ?? [] {
                guard let id = album.id, !seen.contains(id) else { continue }
                seen.insert(id)
                ids.append(id)
            }
        }

        guard !ids.isEmpty else { return [] }
        return ((try? await fetchAlbums(ids: Array(ids.prefix(40)))) ?? [])
            .filter { $0.id != 0 }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private func catalogRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let activeToken = token
        request.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        request.setValue("WindowsPhone/4.75 (Windows Phone 8.1; Microsoft; Lumia 950)", forHTTPHeaderField: "User-Agent")
        request.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        return request
    }
}
