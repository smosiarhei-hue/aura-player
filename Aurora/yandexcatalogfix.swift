import Foundation

// MARK: - Catalog compatibility types

typealias YMArtistBrief = YandexMusicService.YMArtistItem.YMArtistBrief

private struct YMCatalogArtistCover: Decodable {
    let uri: String?
}

private struct YMCatalogSearchArtist: Decodable {
    let id: Int?
    let name: String?
    let coverUri: String?
    let cover: YMCatalogArtistCover?
}

private struct YMCatalogSearchResponse: Decodable {
    struct Result: Decodable {
        struct TracksBlock: Decodable {
            let results: [YandexMusicService.YMTrackItem]?
        }
        struct ArtistsBlock: Decodable {
            let results: [YMCatalogSearchArtist]?
        }
        struct AlbumsBlock: Decodable {
            let results: [YandexMusicService.YMAlbumItem]?
        }
        let tracks: TracksBlock?
        let artists: ArtistsBlock?
        let albums: AlbumsBlock?
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
    func searchAllFixed(query: String) async -> GlobalSearchResults {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return GlobalSearchResults() }

        var components = URLComponents(string: Self.apiBase + "/search")!
        components.queryItems = [
            URLQueryItem(name: "text", value: clean),
            URLQueryItem(name: "type", value: "all"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "nocorrect", value: "false")
        ]

        guard let url = components.url,
              let pair = try? await URLSession.shared.data(for: catalogRequest(url: url)),
              let decoded = try? JSONDecoder().decode(YMCatalogSearchResponse.self, from: pair.0) else {
            return GlobalSearchResults()
        }

        let normalized = clean.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        var tracks = Self.playable(decoded.result?.tracks?.results ?? [])
        tracks.sort { left, right in
            let leftArtistExact = left.artists?.contains {
                ($0.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
            } == true
            let rightArtistExact = right.artists?.contains {
                ($0.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
            } == true
            if leftArtistExact != rightArtistExact { return leftArtistExact }

            let leftTitle = left.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rightTitle = right.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let leftExact = leftTitle == normalized
            let rightExact = rightTitle == normalized
            if leftExact != rightExact { return leftExact }
            let leftStarts = leftTitle.hasPrefix(normalized)
            let rightStarts = rightTitle.hasPrefix(normalized)
            if leftStarts != rightStarts { return leftStarts }
            return leftTitle.count < rightTitle.count
        }

        var artists = (decoded.result?.artists?.results ?? []).compactMap { raw -> YMArtistBrief? in
            guard let id = raw.id, let name = raw.name else { return nil }
            return YMArtistBrief(
                id: String(id),
                name: name,
                coverUri: raw.coverUri ?? raw.cover?.uri
            )
        }
        artists.sort { left, right in
            let leftName = left.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rightName = right.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let leftExact = leftName == normalized
            let rightExact = rightName == normalized
            if leftExact != rightExact { return leftExact }
            let leftStarts = leftName.hasPrefix(normalized)
            let rightStarts = rightName.hasPrefix(normalized)
            if leftStarts != rightStarts { return leftStarts }
            return leftName.count < rightName.count
        }

        var albums = (decoded.result?.albums?.results ?? []).filter { $0.id != 0 }
        albums.sort { left, right in
            let leftArtistExact = left.artists?.contains {
                ($0.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
            } == true
            let rightArtistExact = right.artists?.contains {
                ($0.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized
            } == true
            if leftArtistExact != rightArtistExact { return leftArtistExact }

            let leftTitle = left.displayTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rightTitle = right.displayTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let leftExact = leftTitle == normalized
            let rightExact = rightTitle == normalized
            if leftExact != rightExact { return leftExact }
            return (left.year ?? 0) > (right.year ?? 0)
        }

        return GlobalSearchResults(
            tracks: tracks,
            artists: artists,
            albums: albums,
            suggestions: []
        )
    }

    /// Загружает страницу артиста. Если нестабильный brief-info изменил формат,
    /// экран собирается из отдельного запроса треков и их альбомов.
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
        var components = URLComponents(string: Self.apiBase + "/artists/" + artistId + "/brief-info")!
        components.queryItems = [
            URLQueryItem(name: "popularTracks", value: "true"),
            URLQueryItem(name: "discography", value: "true"),
            URLQueryItem(name: "similarArtists", value: "true")
        ]
        guard let url = components.url,
              let pair = try? await URLSession.shared.data(for: catalogRequest(url: url)),
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
        let activeToken = token.isEmpty ? Self.defaultToken : token
        request.setValue("OAuth " + activeToken, forHTTPHeaderField: "Authorization")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        request.setValue("WindowsPhone/4.75 (Windows Phone 8.1; Microsoft; Lumia 950)", forHTTPHeaderField: "User-Agent")
        request.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        return request
    }
}
