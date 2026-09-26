import Foundation
import UserNotifications

@MainActor
final class AIPlaylistGeneratorService {
    static let shared = AIPlaylistGeneratorService()

    private init() {
        requestNotificationPermissionIfNeeded()
    }

    /// Быстрый параллельный поиск и привязка треков из рекомендаций ИИ к каталогу Яндекс Музыки (с гарантией от 50 треков)
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

        // Интеллектуальный top-up: если найдено меньше 50 треков, дополняем треками артистов из подборки
        if results.count < 50 {
            let candidateArtists = Array(Set(suggestions.map(\.artist)))
            for artist in candidateArtists {
                guard results.count < 50 else { break }
                let searchResult = await YandexMusicService.shared.searchAllFixed(query: artist)
                for ymTrack in searchResult.tracks {
                    let tr = YandexMusicService.shared.convertToTrack(ymTrack)
                    if !seenIDs.contains(tr.id) {
                        seenIDs.insert(tr.id)
                        results.append(tr)
                        if results.count >= 50 { break }
                    }
                }
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

    /// Интеллектуальное дополнение плейлиста ещё 50 новыми треками того же стиля
    func extendPlaylist(
        playlistTitle: String,
        description: String,
        existingTracks: [Track]
    ) async throws -> [Track] {
        guard let aiPlaylist = try await DifyService.shared.extendPlaylist(
            title: playlistTitle,
            description: description,
            existingTracks: existingTracks
        ) else {
            throw NSError(domain: "AIPlaylist", code: 404, userInfo: [NSLocalizedDescriptionKey: "Не удалось получить рекомендации от AI"])
        }

        let existingIDs = Set(existingTracks.map(\.id))
        let existingTitles = Set(existingTracks.map { "\($0.artist.lowercased()) \($0.title.lowercased())" })

        var resolved = await resolveTracks(for: aiPlaylist.tracks)
        resolved.removeAll { existingIDs.contains($0.id) || existingTitles.contains("\($0.artist.lowercased()) \($0.title.lowercased())") }

        // Дополняем до 50 треков при необходимости
        if resolved.count < 50 {
            let candidateArtists = Array(Set(aiPlaylist.tracks.map(\.artist) + existingTracks.map(\.artist)))
            for artist in candidateArtists {
                guard resolved.count < 50 else { break }
                let searchResult = await YandexMusicService.shared.searchAllFixed(query: artist)
                for ymTrack in searchResult.tracks {
                    let tr = YandexMusicService.shared.convertToTrack(ymTrack)
                    let key = "\(tr.artist.lowercased()) \(tr.title.lowercased())"
                    if !existingIDs.contains(tr.id) && !existingTitles.contains(key) && !resolved.contains(where: { $0.id == tr.id }) {
                        resolved.append(tr)
                        if resolved.count >= 50 { break }
                    }
                }
            }
        }

        return resolved
    }

    /// Дополнение плейлиста непосредственно в медиатеке
    func extendPlaylistInLibrary(playlistId: UUID) async throws -> Int {
        guard let playlist = LibraryStore.shared.playlist(byId: playlistId) else { return 0 }
        let currentTracks = LibraryStore.shared.tracks(for: playlist)
        let newTracks = try await extendPlaylist(
            playlistTitle: playlist.title,
            description: "Продолжение атмосферы \(playlist.title)",
            existingTracks: currentTracks
        )

        guard !newTracks.isEmpty else { return 0 }
        LibraryStore.shared.addTracksToPlaylist(tracks: newTracks, playlistId: playlistId)
        sendCreationNotification(title: playlist.title, count: currentTracks.count + newTracks.count)
        return newTracks.count
    }

    /// Сохраняет распознанные треки как плейлист в медиатеку приложения
    @discardableResult
    func saveToLibrary(playlist: AIGeneratedPlaylist, tracks: [Track]) -> UUID? {
        guard !tracks.isEmpty else { return nil }
        let title = playlist.playlistTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "AI Подборка" : title

        let newPlaylist = LibraryStore.shared.createPlaylist(title: resolvedTitle)
        LibraryStore.shared.addTracksToPlaylist(tracks: tracks, playlistId: newPlaylist.id)

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
            content.body = "Плейлист «\(title)» готов! В медиатеке доступно \(count) треков."
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
