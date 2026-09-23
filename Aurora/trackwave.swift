import Foundation

private struct TrackWaveCandidate {
    let item: YandexMusicService.YMTrackItem
    var score: Double
}

@MainActor
extension YandexMusicService {
    /// Builds a diverse queue related to the current song. The catalog remains
    /// the source of truth; a local ranker combines track radio, artist similarity,
    /// album affinity, duration proximity and listening history. When the
    /// Gemini proxy is configured, its semantic ordering wins and the local
    /// score becomes the fallback for candidates Gemini skipped.
    func buildTrackWave(from seed: Track, target: Int = 45) async -> [Track] {
        let seedID = Self.ymId(fromFileName: seed.fileName)
            ?? seed.streamUrlString?.replacingOccurrences(of: "ym_", with: "").replacingOccurrences(of: ".mp3", with: "")

        if let seedID {
            beginStationSession("track:\(seedID)")
        } else {
            beginStationSession("track:\(seed.title)")
        }

        // 1. Извлекаем 6D аудио-вектор вайба для seed-трека (BPM, энергия, валентность, акустичность, грув)
        let seedVector = MoodRadioEngine.shared.extractVector(for: seed)

        var candidates: [String: TrackWaveCandidate] = [:]
        var seedItem: YMTrackItem?

        let normalizedSeedArtists = Set(
            seed.artist
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        func add(_ item: YMTrackItem, baseScore: Double, rank: Int = 0) {
            guard item.available != false else { return }
            if let seedID, item.id == seedID { return }
            if isRecentlyPlayed(ymTrackId: item.id) { return }

            let candidateTrack = convertToTrack(item)
            if UserTasteEngine.shared.isDisliked(track: candidateTrack) { return }

            // Анализируем реальный вайб кандидата
            let candidateVector = MoodRadioEngine.shared.extractVector(for: candidateTrack)
            let vibeSim = seedVector.cosineSimilarity(to: candidateVector) // [-1.0 ... 1.0]

            // Отсекаем треки с совершенно несовместимым вайбом
            guard vibeSim >= 0.45 else { return }

            // Базовый счет основан на близости вайба (0..100) плюс источник и позиция
            var score = (vibeSim * 100.0) + baseScore - Double(rank) * 0.45

            // Никаких бонусов тому же артисту или альбому (убираем монополию)!
            // Небольшая поправка на длительность (близость по форме композиции)
            if seed.duration > 0, item.duration > 0 {
                let ratio = abs(seed.duration - item.duration) / max(seed.duration, item.duration)
                score += max(0, 6 * (1 - ratio))
            }

            // Рандомизация порядка внутри близких по вайбу треков
            score += Double.random(in: 0...3.5)

            if let existing = candidates[item.id] {
                candidates[item.id] = TrackWaveCandidate(
                    item: item,
                    score: max(existing.score, score) + 3
                )
            } else {
                candidates[item.id] = TrackWaveCandidate(item: item, score: score)
            }
        }

        // 1. Нативное радио трека — алгоритмические рекомендации Яндекса для этого трека
        if let seedID {
            let radio = (try? await getStationTracks(stationId: "track:\(seedID)")) ?? []
            for (index, item) in radio.enumerated() {
                add(item, baseScore: 110, rank: index)
            }
            seedItem = radio.first { $0.id == seedID }
        }

        // 2. Точный поиск сущности для расширения поиска
        if seedItem == nil {
            let query = "\(seed.artist) \(seed.title)"
            let search = await searchAllFixed(query: query)
            if let seedID {
                seedItem = search.tracks.first { $0.id == seedID }
            }
            if seedItem == nil {
                let title = seed.title.lowercased()
                seedItem = search.tracks.first { $0.title.lowercased() == title }
            }
        }

        // 3. Широкий сбор похожих артистов (перемешиваем из топ-15+, чтобы не было одних и тех же 6)
        let artistIDs = (seedItem?.artists ?? []).compactMap { $0.id }.map(String.init)
        for artistID in artistIDs.prefix(2) {
            // Станция артиста подбирает похожих исполнителей
            let artistRadio = (try? await getStationTracks(stationId: "artist:\(artistID)")) ?? []
            for (index, item) in artistRadio.prefix(25).enumerated() {
                add(item, baseScore: 100, rank: index)
            }

            if let profile = try? await getArtistFixed(artistId: artistID) {
                // Берем перемешанных похожих артистов с разными страницами пагинации
                let similarPool = profile.similarArtists.shuffled().prefix(10)
                for similar in similarPool {
                    let page = Int.random(in: 0...1)
                    let tracks = (try? await getArtistTracks(
                        artistId: similar.id,
                        page: page,
                        pageSize: 6
                    )) ?? []
                    for (index, item) in tracks.enumerated() {
                        add(item, baseScore: 95, rank: index)
                    }
                }
            }
        }

        // 4. Комплементарные станции Яндекса, точно соответствующие аудио-вектору (вайбу)
        let matchingStations = vibeStations(for: seedVector)
        for station in matchingStations.prefix(2) {
            let stationTracks = (try? await getStationTracks(stationId: station)) ?? []
            for (index, item) in stationTracks.shuffled().prefix(15).enumerated() {
                add(item, baseScore: 90, rank: index)
            }
        }

        // 5. Локальная библиотека и избранное с подходящим вайбом (similarity >= 0.70)
        let matchingFavorites = LibraryStore.shared.favorites.filter { fav in
            let vec = MoodRadioEngine.shared.extractVector(for: fav)
            return vec.cosineSimilarity(to: seedVector) >= 0.70 &&
                   !isRecentlyPlayed(ymTrackId: PlayerCore.yandexTrackID(from: fav)) &&
                   !UserTasteEngine.shared.isDisliked(track: fav)
        }
        for (index, fav) in matchingFavorites.shuffled().prefix(10).enumerated() {
            if let ymId = Self.ymId(fromFileName: fav.fileName) ?? fav.streamUrlString?.replacingOccurrences(of: "ym_", with: "").replacingOccurrences(of: ".mp3", with: "") {
                let fakeItem = YMTrackItem(
                    id: ymId,
                    title: fav.title,
                    available: true,
                    artists: [YMTrackItem.YMArtist(id: nil, name: fav.artist)],
                    albums: nil,
                    durationMs: Int(fav.duration * 1000),
                    ogImage: fav.artworkUrl?.absoluteString
                )
                add(fakeItem, baseScore: 92, rank: index)
            }
        }

        // 6. Gemini semantic rerank (если настроен)
        var aiPositions: [String: Int] = [:]
        if AIRankerService.shared.isConfigured {
            let aiCandidates = Array(candidates.values.prefix(60)).map {
                AIRankerService.Candidate(
                    id: $0.item.id,
                    title: $0.item.title,
                    artist: $0.item.artistName,
                    album: $0.item.albumName,
                    duration: $0.item.duration
                )
            }
            if let ranking = await AIRankerService.shared.rank(
                seed: .init(
                    title: seed.title,
                    artist: seed.artist,
                    album: seed.album,
                    duration: seed.duration
                ),
                intent: "Продолжить волну по вайбу: \(seed.artist) — \(seed.title)",
                candidates: aiCandidates
            ), !ranking.ordered_ids.isEmpty {
                for (position, id) in ranking.ordered_ids.enumerated() {
                    aiPositions[id] = position
                }
            }
        }

        let sorted: [TrackWaveCandidate]
        if aiPositions.isEmpty {
            sorted = candidates.values.sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.item.id < right.item.id
            }
        } else {
            sorted = candidates.values.sorted { left, right in
                switch (aiPositions[left.item.id], aiPositions[right.item.id]) {
                case let (leftPosition?, rightPosition?):
                    return leftPosition < rightPosition
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                default:
                    if left.score != right.score { return left.score > right.score }
                    return left.item.id < right.item.id
                }
            }
        }

        // 7. СТРОГИЙ АНТИ-ПОВТОР АРТИСТОВ:
        // Максимум 1 трек от одного артиста во всей волне!
        // Исходного исполнителя seed включаем максимум 1 раз.
        var artistCounts: [String: Int] = [:]
        var result: [Track] = []
        var seedArtistIncluded = false

        for candidate in sorted {
            let primaryArtist = candidate.item.artists?.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "unknown"
            let candidateArtistNames = Set((candidate.item.artists ?? []).compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            let isSeedArtist = !normalizedSeedArtists.isDisjoint(with: candidateArtistNames)

            if isSeedArtist {
                if seedArtistIncluded { continue }
                seedArtistIncluded = true
            } else {
                guard artistCounts[primaryArtist, default: 0] < 1 else { continue }
                artistCounts[primaryArtist, default: 0] += 1
            }

            result.append(convertToTrack(candidate.item))
            if result.count >= target { break }
        }

        // Применяем пользовательские вкусовые предпочтения (лайки/язык)
        return UserTasteEngine.shared.filterAndRankWave(tracks: result)
    }

    /// Персональная волна по артисту в духе Яндекс Музыки:
    /// подбирает 1-2 главных хита артиста, а далее разворачивает полноценный поток
    /// из похожих исполнителей с тем же вайбом, жанром и настроением без монотонных повторов.
    func buildArtistWave(artistId: String, target: Int = 45) async -> [Track] {
        beginStationSession("artist:\(artistId)")
        var candidates: [TrackWaveCandidate] = []
        var seen = Set<String>()
        var artistCounts: [String: Int] = [:]

        // 1. Нативная станция Яндекса по артисту (ротор отдает треки похожих артистов того же настроения)
        let rotor = (try? await getStationTracks(stationId: "artist:\(artistId)")) ?? []
        for (idx, item) in rotor.enumerated() {
            guard !seen.contains(item.id), !isRecentlyPlayed(ymTrackId: item.id) else { continue }
            seen.insert(item.id)
            candidates.append(TrackWaveCandidate(item: item, score: 120.0 - Double(idx) * 0.5))
        }

        // 2. Каталог артиста и похожие музыканты
        var targetArtistName: String?
        if let profile = try? await getArtistFixed(artistId: artistId) {
            targetArtistName = profile.artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            // Добавляем 2 визитные карточки артиста в начало
            for (idx, item) in profile.popularTracks.prefix(2).enumerated() {
                if !seen.contains(item.id) {
                    seen.insert(item.id)
                    candidates.append(TrackWaveCandidate(item: item, score: 130.0 - Double(idx) * 2.0))
                }
            }

            // Похожие артисты
            for similar in profile.similarArtists.shuffled().prefix(10) {
                let tracks = (try? await getArtistTracks(artistId: similar.id, page: 0, pageSize: 6)) ?? []
                for (idx, item) in tracks.prefix(3).enumerated() {
                    guard !seen.contains(item.id), !isRecentlyPlayed(ymTrackId: item.id) else { continue }
                    seen.insert(item.id)
                    candidates.append(TrackWaveCandidate(item: item, score: 110.0 - Double(idx) * 1.5))
                }
            }
        }

        // Сортируем: для главного артиста разрешено до 2 треков, для похожих артистов строго по 1 треку
        candidates.sort { $0.score > $1.score }
        var result: [Track] = []
        for c in candidates {
            let primary = c.item.artists?.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "unknown"
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
