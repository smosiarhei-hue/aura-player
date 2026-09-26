import Foundation
import UserNotifications

@MainActor
final class AIPlaylistGeneratorService {
    static let shared = AIPlaylistGeneratorService()

    private init() {
        requestNotificationPermissionIfNeeded()
    }

    /// Быстрый параллельный поиск и привязка треков из рекомендаций ИИ к каталогу Яндекс Музыки
    func resolveTracks(for suggestions: [AITrackSuggestion]) async -> [Track] {
        guard !suggestions.isEmpty else { return [] }

        // Параллельное асинхронное разрешение с сохранением исходного порядка
        let indexedSuggestions = Array(suggestions.enumerated())
        let resolvedMap: [Int: Track] = await withTaskGroup(of: (Int, Track?).self) { group in
            for (index, item) in indexedSuggestions {
                group.addTask {
                    let matched = await Self.searchSingleTrack(item)
                    return (index, matched)
                }
            }

            var dict: [Int: Track] = [:]
            for await (index, track) in group {
                if let track {
                    dict[index] = track
                }
            }
            return dict
        }

        var results: [Track] = []
        var seenIDs: Set<UUID> = []

        for index in 0..<suggestions.count {
            if let track = resolvedMap[index], !seenIDs.contains(track.id) {
                seenIDs.insert(track.id)
                results.append(track)
            }
        }

        return results
    }

    /// Трёхуровневый интеллектуальный поиск трека с fallback-стратегией
    private static func searchSingleTrack(_ item: AITrackSuggestion) async -> Track? {
        let artist = item.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Прямой точный поиск: "Исполнитель Название"
        if !artist.isEmpty && !title.isEmpty {
            let direct = await YandexMusicService.shared.searchAllFixed(query: "\(artist) \(title)")
            if let first = direct.tracks.first {
                return YandexMusicService.shared.convertToTrack(first)
            }
        }

        // 2. Поиск только по названию трека
        if !title.isEmpty {
            let byTitle = await YandexMusicService.shared.searchAllFixed(query: title)
            if let first = byTitle.tracks.first {
                return YandexMusicService.shared.convertToTrack(first)
            }
        }

        // 3. Поиск по исполнителю (лучший трек артиста)
        if !artist.isEmpty {
            let byArtist = await YandexMusicService.shared.searchAllFixed(query: artist)
            if let first = byArtist.tracks.first {
                return YandexMusicService.shared.convertToTrack(first)
            }
        }

        return nil
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

        sendCreationNotification(title: resolvedTitle, count: tracks.count)
        return newPlaylist.id
    }

    /// Мгновенный запуск воспроизведения подборки
    func playNow(tracks: [Track]) {
        guard let first = tracks.first else { return }
        Haptics.tap(.heavy)
        PlaybackCommandRouter.shared.play(first, queue: tracks)
    }

    // MARK: - Уведомления ассистента

    func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendCreationNotification(title: String, count: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "🎶 AI Куратор Sonivo"
            content.body = "Плейлист «\(title)» готов! Добавлено \(count) треков в вашу медиатеку."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "ai-playlist-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            center.add(request) { _ in }
        }
    }
}
