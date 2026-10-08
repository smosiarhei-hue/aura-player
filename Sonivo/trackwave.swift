import Foundation

private struct ArtistWaveCandidate {
    let item: YandexMusicService.YMTrackItem
    var score: Double
}

@MainActor
extension YandexMusicService {
    /// Track radio is selected and ordered by Yandex's rotor only.
    /// Local files without a catalog ID cannot be used as a station seed.
    func buildTrackWave(from seed: Track, target: Int = 45) async -> [Track] {
        guard let seedID = Self.ymId(fromFileName: seed.fileName), !seedID.isEmpty else { return [] }
        return await startYandexTrackStation(seedID: seedID, target: target)
    }

    /// Персональная волна по артисту в духе Яндекс Музыки:
    /// подбирает 1-2 главных хита артиста, а далее разворачивает полноценный поток
    /// из похожих исполнителей с тем же вайбом, жанром и настроением без монотонных повторов.
    func buildArtistWave(artistId: String, target: Int = 45) async -> [Track] {
        beginStationSession("artist:\(artistId)")
        var candidates: [ArtistWaveCandidate] = []
        var seen = Set<String>()
        var artistCounts: [String: Int] = [:]

        // 1. Нативная станция Яндекса по артисту (ротор отдает треки похожих артистов того же настроения)
        let rotor = (try? await getStationTracks(stationId: "artist:\(artistId)")) ?? []
        for (idx, item) in rotor.enumerated() {
            guard !seen.contains(item.id), !isRecentlyPlayed(ymTrackId: item.id) else { continue }
            seen.insert(item.id)
            candidates.append(ArtistWaveCandidate(item: item, score: 120.0 - Double(idx) * 0.5))
        }

        // 2. Каталог артиста и похожие музыканты
        var targetArtistName: String?
        if let profile = try? await getArtistFixed(artistId: artistId) {
            targetArtistName = profile.name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()

            // Добавляем 2 визитные карточки артиста в начало
            for (idx, item) in profile.popularTracks.prefix(2).enumerated() {
                if !seen.contains(item.id) {
                    seen.insert(item.id)
                    candidates.append(ArtistWaveCandidate(item: item, score: 130.0 - Double(idx) * 2.0))
                }
            }

            // Похожие артисты
            for similar in profile.similarArtists.shuffled().prefix(10) {
                let tracks = (try? await getArtistTracks(artistId: similar.id, page: 0, pageSize: 6)) ?? []
                for (idx, item) in tracks.prefix(3).enumerated() {
                    guard !seen.contains(item.id), !isRecentlyPlayed(ymTrackId: item.id) else { continue }
                    seen.insert(item.id)
                    candidates.append(ArtistWaveCandidate(item: item, score: 110.0 - Double(idx) * 1.5))
                }
            }
        }

        // Сортируем: для главного артиста разрешено до 2 треков, для похожих артистов строго по 1 треку
        candidates.sort { $0.score > $1.score }
        var result: [Track] = []
        for c in candidates {
            let primary = c.item.artists?.first?.name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() ?? "unknown"
            let maxAllowed = (primary == targetArtistName) ? 2 : 1
            if artistCounts[primary, default: 0] < maxAllowed {
                artistCounts[primary, default: 0] += 1
                result.append(convertToTrack(c.item))
                if result.count >= target { break }
            }
        }

        return UserTasteEngine.shared.filterAndRankWave(tracks: result)
    }
}
