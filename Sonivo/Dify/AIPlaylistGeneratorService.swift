import Foundation

@MainActor
final class AIPlaylistGeneratorService {
    static let shared = AIPlaylistGeneratorService()
    private init() {}

    /// Recommendations only: never pad a selection with unrelated chart/library tracks.
    func resolveTracks(for suggestions: [AITrackSuggestion]) async -> [Track] {
        let service = YandexMusicService.shared
        guard service.isUserLoggedIn, !Task.isCancelled else { return [] }
        let account = service.accountGeneration
        let items = Array(suggestions.prefix(AICuratorPolicy.suggestionLimit))
        let resolved: [Int: Track] = await withTaskGroup(of: (Int, Track?).self) { group in
            var map: [Int: Track] = [:]
            var iterator = items.enumerated().makeIterator()
            for _ in 0..<4 {
                if let (index, item) = iterator.next() {
                    group.addTask { (index, await Self.searchSingleTrack(item)) }
                }
            }
            for await (index, track) in group {
                guard !Task.isCancelled, service.accountGeneration == account else { group.cancelAll(); break }
                if let track { map[index] = track }
                if let (index, item) = iterator.next() {
                    group.addTask { (index, await Self.searchSingleTrack(item)) }
                }
            }
            return map
        }
        guard !Task.isCancelled, service.accountGeneration == account else { return [] }
        var seen = Set<UUID>()
        return items.indices.compactMap { index in
            guard let track = resolved[index], seen.insert(track.id).inserted else { return nil }
            return track
        }
    }

    private static func searchSingleTrack(_ item: AITrackSuggestion) async -> Track? {
        guard !Task.isCancelled else { return nil }
        let service = YandexMusicService.shared
        let account = service.accountGeneration
        let result = await service.searchAllFixed(query: "\(item.artist) \(item.title)")
        guard !Task.isCancelled, service.accountGeneration == account,
              let match = result.tracks.first(where: { candidate in
                  candidate.available != false && AICuratorPolicy.matches(
                    artist: item.artist, title: item.title,
                    candidateArtist: candidate.artists?.compactMap(\.name).joined(separator: ", ") ?? "",
                    candidateTitle: candidate.title)
              }) else { return nil }
        return service.convertToTrack(match)
    }

    func extendPlaylist(playlistTitle: String, description: String, existingTracks: [Track], webContext: String = "") async throws -> [Track] {
        let account = YandexMusicService.shared.accountGeneration
        guard YandexMusicService.shared.isUserLoggedIn else { throw DifyError.unauthorized }
        guard let playlist = try await DifyService.shared.extendPlaylist(
            title: playlistTitle, description: description, existingTracks: existingTracks, webContext: webContext) else { throw DifyError.emptyAnswer }
        try Task.checkCancellation()
        let tracks = await resolveTracks(for: playlist.tracks)
        try Task.checkCancellation()
        guard account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
        let ids = Set(existingTracks.map(\.id))
        let names = Set(existingTracks.map { AICuratorPolicy.normalized($0.artist + " " + $0.title) })
        return tracks.filter { !ids.contains($0.id) && !names.contains(AICuratorPolicy.normalized($0.artist + " " + $0.title)) }
    }

    func extendPlaylistInLibrary(playlistId: UUID) async throws -> Int {
        guard let playlist = LibraryStore.shared.playlist(byId: playlistId) else { return 0 }
        let current = LibraryStore.shared.tracks(for: playlist)
        let tracks = try await extendPlaylist(playlistTitle: playlist.title,
            description: "Продолжение атмосферы \(playlist.title)", existingTracks: current)
        try Task.checkCancellation()
        guard LibraryStore.shared.playlist(byId: playlistId) != nil else { return 0 }
        // Re-read after await: another screen may have changed the same playlist.
        let latest = LibraryStore.shared.playlist(byId: playlistId)!
        let existing = Set(LibraryStore.shared.tracks(for: latest).map(\.id))
        let additions = tracks.filter { !existing.contains($0.id) }
        LibraryStore.shared.addTracksToPlaylist(tracks: additions, playlistId: playlistId)
        return additions.count
    }

    @discardableResult
    func saveToLibrary(playlist: AIGeneratedPlaylist, tracks: [Track]) -> UUID? {
        guard !tracks.isEmpty else { return nil }
        let title = playlist.playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverURL = tracks.first(where: { !($0.coverURL?.isEmpty ?? true) })?.coverURL
        return LibraryStore.shared.createPlaylist(title: title.isEmpty ? "Подборка куратора" : title,
            coverURL: coverURL, initialTracks: tracks).id
    }

    func playNow(tracks: [Track]) {
        guard let first = tracks.first else { return }
        Haptics.tap(.medium)
        PlaybackCommandRouter.shared.play(first, queue: tracks)
    }
}
