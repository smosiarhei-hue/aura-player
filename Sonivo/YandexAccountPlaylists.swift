import Foundation

extension YandexMusicService {
    // Imports metadata only; no full-track download or PCM retention.
    func syncPersonalPlaylists(uid: Int, generation: UUID) async -> Bool {
        guard currentUser?.uid == uid, accountGeneration == generation,
              let url = URL(string: Self.apiBase + "/users/\(uid)/playlists/list") else { return false }
        do {
            let (data, response) = try await sessionData(for: URLRequest(url: url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let list = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(YandexPlaylistList.self, from: data).result
            }.value
            try Task.checkCancellation()
            guard currentUser?.uid == uid, accountGeneration == generation else { return false }
            // Bound startup traffic; report a partial import instead of implying all were loaded.
            guard list.count <= 50 else { return false }
            var imported: [Playlist] = []
            for info in list {
                try Task.checkCancellation()
                guard accountGeneration == generation, currentUser?.uid == uid,
                      let detailURL = URL(string: Self.apiBase + "/users/\(uid)/playlists/\(info.kind)") else { return false }
                let (detailData, detailResponse) = try await sessionData(for: URLRequest(url: detailURL))
                guard (detailResponse as? HTTPURLResponse)?.statusCode == 200 else { return false }
                let detail = try await Task.detached(priority: .utility) {
                    try JSONDecoder().decode(YandexPlaylistDetail.self, from: detailData).result
                }.value
                guard let entries = detail.tracks, entries.count <= 2000 else { return false }
                let items = entries.compactMap(\.track)
                // Missing embedded tracks must not silently create an incomplete playlist.
                guard items.count == entries.count else { return false }
                let tracks = await Task.detached(priority: .utility) { items.map { self.convertToTrack($0) } }.value
                try Task.checkCancellation()
                guard accountGeneration == generation, currentUser?.uid == uid else { return false }
                let id = UUID(uuidString: Self.stableKey(for: "playlist:\(uid):\(info.kind)"))!
                imported.append(Playlist(id: id, title: detail.title ?? info.title ?? "Плейлист",
                                         trackIds: tracks.map(\.id), coverURL: tracks.first?.coverURL,
                                         cachedTracks: tracks))
            }
            guard !Task.isCancelled, accountGeneration == generation, currentUser?.uid == uid else { return false }
            LibraryStore.shared.setYandexPlaylistsFromCloud(imported)
            return true
        } catch { return false }
    }
}

nonisolated private struct YandexPlaylistInfo: Decodable, Sendable {
    let kind: String
    let title: String?
    enum CodingKeys: String, CodingKey { case kind, title }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .kind) {
            guard !string.isEmpty, string.allSatisfy({ $0.isNumber && $0.isASCII }) else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Invalid playlist identifier")
            }
            kind = string
        } else {
            let number = try container.decode(Int.self, forKey: .kind)
            guard number >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Invalid playlist identifier")
            }
            kind = String(number)
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}

nonisolated private struct YandexPlaylistList: Decodable, Sendable { let result: [YandexPlaylistInfo] }
nonisolated private struct YandexPlaylistDetail: Decodable, Sendable {
    nonisolated struct Entry: Decodable, Sendable { let track: YandexMusicService.YMTrackItem? }
    nonisolated struct Contents: Decodable, Sendable { let title: String?; let tracks: [Entry]? }
    let result: Contents
}
