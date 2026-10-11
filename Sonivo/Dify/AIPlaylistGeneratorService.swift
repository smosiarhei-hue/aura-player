import Foundation

nonisolated struct CuratorExtensionResult: Sendable {
    let tracks: [Track]
    let suggestions: [AITrackSuggestion]
}

@MainActor
final class AIPlaylistGeneratorService {
    static let shared = AIPlaylistGeneratorService()
    private init() {}

    /// Recommendations only: never pad a selection with unrelated chart/library tracks.
    func resolveTracks(for suggestions: [AITrackSuggestion], yearRange: CuratorYearRange? = nil,
                       rules: CuratorSelectionRules = .init(), existingTracks: [Track] = [],
                       onProgress: ((Int, Int) -> Void)? = nil) async -> [Track] {
        let service = YandexMusicService.shared
        guard service.isUserLoggedIn, !Task.isCancelled else { return [] }
        let account = service.accountGeneration
        var seenSuggestions = Set<String>()
        let existingNames = Set(existingTracks.map { AICuratorPolicy.normalized($0.artist + " " + $0.title) })
        let items = Array(suggestions.prefix(AICuratorPolicy.suggestionLimit)).filter {
            let name = AICuratorPolicy.normalized($0.artist + " " + $0.title)
            return !rules.excludes($0.artist) && !existingNames.contains(name) && seenSuggestions.insert(name).inserted
        }
        onProgress?(0,items.count)
        let resolved: [Int: Track] = await withTaskGroup(of: (Int, Track?).self) { group in
            var map: [Int: Track] = [:]
            var completed = 0
            var iterator = items.enumerated().makeIterator()
            for _ in 0..<4 {
                if let (index, item) = iterator.next() {
                    group.addTask { (index, await Self.searchSingleTrack(item, yearRange: yearRange, rules: rules)) }
                }
            }
            for await (index, track) in group {
                guard !Task.isCancelled, service.accountGeneration == account else { group.cancelAll(); break }
                if let track { map[index] = track }
                completed += 1; onProgress?(completed,items.count)
                if let (index, item) = iterator.next() {
                    group.addTask { (index, await Self.searchSingleTrack(item, yearRange: yearRange, rules: rules)) }
                }
            }
            return map
        }
        guard !Task.isCancelled, service.accountGeneration == account else { return [] }
        var seen = Set<UUID>()
        let ordered: [Track] = items.indices.compactMap { index in
            guard let track = resolved[index], seen.insert(track.id).inserted else { return nil }
            return track
        }
        return rules.diverse(ordered,existing:existingTracks)
    }

    private static func searchSingleTrack(_ item: AITrackSuggestion, yearRange: CuratorYearRange?, rules: CuratorSelectionRules) async -> Track? {
        guard !Task.isCancelled else { return nil }
        let service = YandexMusicService.shared
        let account = service.accountGeneration
        guard let candidates = try? await service.searchCuratorTracks(query: "\(item.artist) \(item.title)") else { return nil }
        guard !Task.isCancelled, service.accountGeneration == account,
              let match = candidates.first(where: { candidate in
                  let catalogYears = candidate.albums?.compactMap(\.year).filter { $0 >= 1900 && $0 <= 2099 } ?? []
                  let periodMatches = yearRange.map { range in catalogYears.min().map(range.contains) ?? false } ?? true
                  return candidate.available != false && periodMatches && !(candidate.artists?.compactMap(\.name).contains(where:rules.excludes) ?? false) && AICuratorPolicy.matchesCatalog(
                    artist:item.artist,title:item.title,candidateArtists:candidate.artists?.compactMap(\.name) ?? [],
                    candidateTitle:candidate.title,version:candidate.version)
              }) else { return nil }
        return service.convertToTrack(match)
    }

    func extendPlaylistDetailed(playlistTitle: String, description: String, existingTracks: [Track],
                                webContext: String = "", yearRange: CuratorYearRange? = nil,
                                count: Int = 10, originalRequest: String = "", rules: CuratorSelectionRules = .init(),
                                suggestedBefore: [AITrackSuggestion] = [], onProgress: ((Int,Int) -> Void)? = nil) async throws -> CuratorExtensionResult {
        let account = YandexMusicService.shared.accountGeneration
        guard YandexMusicService.shared.isUserLoggedIn else { throw DifyError.unauthorized }
        guard let playlist = try await DifyService.shared.extendPlaylist(title:playlistTitle,description:description,
            existingTracks:existingTracks,webContext:webContext + AICuratorRequest.periodContext(yearRange) + rules.promptContext,
            count:count,originalRequest:originalRequest,suggestedBefore:suggestedBefore) else { throw DifyError.emptyAnswer }
        try Task.checkCancellation()
        let suggestions = Array(playlist.tracks.prefix(min(50,max(1,count))))
        let forbidden = Set(suggestedBefore.map { AICuratorPolicy.normalized($0.artist + " " + $0.title) })
        let fresh = suggestions.filter { !forbidden.contains(AICuratorPolicy.normalized($0.artist + " " + $0.title)) }
        let tracks = await resolveTracks(for:fresh,yearRange:yearRange,rules:rules,existingTracks:existingTracks,onProgress:onProgress)
        try Task.checkCancellation()
        guard account == YandexMusicService.shared.accountGeneration else { throw CancellationError() }
        return CuratorExtensionResult(tracks:tracks,suggestions:suggestions)
    }
    func extendPlaylist(playlistTitle: String, description: String, existingTracks: [Track], webContext: String = "", yearRange: CuratorYearRange? = nil) async throws -> [Track] {
        let result = try await extendPlaylistDetailed(playlistTitle:playlistTitle,description:description,
            existingTracks:existingTracks,webContext:webContext,yearRange:yearRange)
        return result.tracks
    }

    func extendPlaylistInLibrary(playlistId: UUID) async throws -> Int {
        guard let playlist = LibraryStore.shared.playlist(byId: playlistId) else { return 0 }
        let current = LibraryStore.shared.tracks(for: playlist)
        let source = AIMusicCuratorStore.shared.messages.first { $0.savedPlaylistID == playlistId }
        let result = try await extendPlaylistDetailed(playlistTitle:playlist.title,
            description:source?.playlist?.description ?? "Продолжение атмосферы \(playlist.title)",existingTracks:current,
            yearRange:source?.requestedYearRange,originalRequest:source?.originalRequest ?? "",
            rules:source?.selectionRules ?? .init(),suggestedBefore:(source?.playlist?.tracks ?? []) + (source?.extensionSuggestions ?? []))
        let tracks = result.tracks
        try Task.checkCancellation()
        guard LibraryStore.shared.playlist(byId: playlistId) != nil else { return 0 }
        // Re-read after await: another screen may have changed the same playlist.
        let latest = LibraryStore.shared.playlist(byId: playlistId)!
        let additions = (source?.selectionRules ?? .init()).diverse(tracks,existing:LibraryStore.shared.tracks(for:latest))
        LibraryStore.shared.addTracksToPlaylist(tracks: additions, playlistId: playlistId)
        AIMusicCuratorStore.shared.recordLibraryExtension(playlistID:playlistId,result:CuratorExtensionResult(tracks:additions,suggestions:result.suggestions))
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
