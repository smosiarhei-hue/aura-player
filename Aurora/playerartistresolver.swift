import Foundation

struct PlayerArtistLink: Identifiable, Hashable {
    let id: String
    let name: String
}

extension YandexMusicService {
    func resolvePlayerArtists(for track: Track) async -> [PlayerArtistLink] {
        if let trackId = Self.ymId(fromFileName: track.fileName),
           let exact = await loadArtistsForPlayerTrack(trackId),
           !exact.isEmpty {
            return exact
        }

        let names = track.artist
            .replacingOccurrences(of: " feat. ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " & ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var links: [PlayerArtistLink] = []
        for name in names.prefix(5) {
            let results = await searchAllFixed(query: name)
            if let artist = results.artists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? results.artists.first {
                links.append(PlayerArtistLink(id: artist.id, name: artist.name))
            }
        }
        return Array(Dictionary(grouping: links, by: \.id).compactMap { $0.value.first })
    }

    private func loadArtistsForPlayerTrack(_ trackId: String) async -> [PlayerArtistLink]? {
        var components = URLComponents(string: Self.apiBase + "/tracks")!
        components.queryItems = [URLQueryItem(name: "track-ids", value: trackId)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("OAuth " + (token.isEmpty ? Self.defaultToken : token), forHTTPHeaderField: "Authorization")
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        request.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        struct Response: Decodable { let result: [YMTrackItem]? }
        guard let item = (try? JSONDecoder().decode(Response.self, from: data))?.result?.first else { return nil }
        return (item.artists ?? []).compactMap { artist in
            guard let id = artist.id, let name = artist.name, !name.isEmpty else { return nil }
            return PlayerArtistLink(id: String(id), name: name)
        }
    }
}
