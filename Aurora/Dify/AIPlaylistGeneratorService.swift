import Foundation

@MainActor
final class AIPlaylistGeneratorService {
    static let shared = AIPlaylistGeneratorService()

    private init() {}

    /// Разрешает список строковых предложений треков через API Яндекс Музыки в реальные объекты Track
    func resolveTracks(for suggestions: [AITrackSuggestion]) async -> [Track] {
        var resolved: [Track] = []

        for item in suggestions {
            let directQuery = "\(item.artist) \(item.title)".trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directQuery.isEmpty else { continue }

            var searchResults = await YandexMusicService.shared.searchAllFixed(query: directQuery)

            // Если прямой поиск не дал результатов, пробуем только название трека
            if searchResults.tracks.isEmpty {
                let titleQuery = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !titleQuery.isEmpty {
                    searchResults = await YandexMusicService.shared.searchAllFixed(query: titleQuery)
                }
            }

            if let matched = searchResults.tracks.first {
                let track = YandexMusicService.shared.convertToTrack(matched)
                if !resolved.contains(where: { $0.id == track.id }) {
                    resolved.append(track)
                }
            }
        }

        return resolved
    }

    /// Сохраняет распознанные треки как плейлист в медиатеку приложения
    @discardableResult
    func saveToLibrary(playlist: AIGeneratedPlaylist, tracks: [Track]) -> UUID? {
        guard !tracks.isEmpty else { return nil }
        let title = playlist.playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "AI Подборка" : title

        LibraryStore.shared.createPlaylist(title: resolvedTitle)
        guard let newPlaylist = LibraryStore.shared.playlists.first else { return nil }

        for track in tracks {
            LibraryStore.shared.addTrackToPlaylist(track: track, playlistId: newPlaylist.id)
        }

        return newPlaylist.id
    }

    /// Мгновенный запуск воспроизведения подборки
    func playNow(tracks: [Track]) {
        guard let first = tracks.first else { return }
        Haptics.tap(.heavy)
        PlaybackCommandRouter.shared.play(first, queue: tracks)
    }
}
