import Foundation
import Observation
import SwiftUI

// MARK: - ТЗ: Mood Radio Engine
// Бесконечная генерация очереди треков по выбранному вектору настроения с обратной связью (re-seeding).

/// 6-мерный вектор характеристик трека (значения нормализованы в диапазоне 0.0 ... 1.0)
struct TrackVector: Codable, Equatable, Sendable {
    var tempo: Double         // Нормализованный BPM (60..180 -> 0.0..1.0)
    var energy: Double        // Энергия / плотность звука / RMS
    var valence: Double       // Гармоническая яркость (мажор/позитив vs минор)
    var acousticness: Double  // Акустичность vs электронный саунд
    var danceability: Double  // Ритмическая устойчивость и грув
    var loudness: Double      // Динамический диапазон

    var values: [Double] {
        [tempo, energy, valence, acousticness, danceability, loudness]
    }

    init(tempo: Double, energy: Double, valence: Double, acousticness: Double, danceability: Double = 0.5, loudness: Double = 0.5) {
        self.tempo = min(1.0, max(0.0, tempo))
        self.energy = min(1.0, max(0.0, energy))
        self.valence = min(1.0, max(0.0, valence))
        self.acousticness = min(1.0, max(0.0, acousticness))
        self.danceability = min(1.0, max(0.0, danceability))
        self.loudness = min(1.0, max(0.0, loudness))
    }

    /// Косинусное сходство между двумя векторами [-1.0 ... 1.0]
    func cosineSimilarity(to other: TrackVector) -> Double {
        let v1 = values
        let v2 = other.values
        var dot: Double = 0
        var mag1: Double = 0
        var mag2: Double = 0
        for i in 0..<v1.count {
            dot += v1[i] * v2[i]
            mag1 += v1[i] * v1[i]
            mag2 += v2[i] * v2[i]
        }
        let denom = sqrt(mag1) * sqrt(mag2)
        guard denom > 0.0001 else { return 0.5 }
        return max(-1.0, min(1.0, dot / denom))
    }

    /// Векторная линейная комбинация
    static func blend(_ v1: TrackVector, weight1: Double, _ v2: TrackVector, weight2: Double) -> TrackVector {
        let sum = weight1 + weight2
        guard sum > 0 else { return v1 }
        return TrackVector(
            tempo: (v1.tempo * weight1 + v2.tempo * weight2) / sum,
            energy: (v1.energy * weight1 + v2.energy * weight2) / sum,
            valence: (v1.valence * weight1 + v2.valence * weight2) / sum,
            acousticness: (v1.acousticness * weight1 + v2.acousticness * weight2) / sum,
            danceability: (v1.danceability * weight1 + v2.danceability * weight2) / sum,
            loudness: (v1.loudness * weight1 + v2.loudness * weight2) / sum
        )
    }

    /// Применение дельты обратной связи (+ или -)
    func applyingDelta(_ delta: TrackVector, weight: Double, positive: Bool) -> TrackVector {
        let factor = positive ? weight : -weight
        return TrackVector(
            tempo: tempo + (delta.tempo - tempo) * factor,
            energy: energy + (delta.energy - energy) * factor,
            valence: valence + (delta.valence - valence) * factor,
            acousticness: acousticness + (delta.acousticness - acousticness) * factor,
            danceability: danceability + (delta.danceability - danceability) * factor,
            loudness: loudness + (delta.loudness - loudness) * factor
        )
    }
}

// MARK: - Пресеты настроений (ТЗ Раздел 3.2)

enum MoodPreset: String, CaseIterable, Identifiable, Sendable {
    case dreamy = "dreamy"       // 💭 Помечтать (низкий темп, низкая энергия, высокая акустика)
    case recap = "recap"         // ⚡ Быстро распаковать (высокий темп, высокая энергия, динамика)
    case energy = "energy"       // 🔋 Заряд (высокий темп, яркий валенс, танцевальность)
    case calm = "calm"           // 🧘 Спокойствие (низкий темп, нежная акустика, умиротворение)
    case sad = "sad"             // 😢 Погрустить (минор, низкая энергия, меланхолия)
    case workout = "workout"     // 🏃 Бежать быстрее ветра (спорт, драйв, ритм)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dreamy:  return "Время\nпомечтать"
        case .recap:   return "Быстро\nраспаковать"
        case .energy:  return "Заряд\nэнергии"
        case .calm:    return "Спокойствие\nи баланс"
        case .sad:     return "Время\nпогрустить"
        case .workout: return "Бежать\nбыстрее ветра"
        }
    }

    var iconName: String {
        switch self {
        case .dreamy:  return "sparkles"
        case .recap:   return "bolt.fill"
        case .energy:  return "flame.fill"
        case .calm:    return "leaf.fill"
        case .sad:     return "drop.fill"
        case .workout: return "figure.run"
        }
    }

    var gradientColors: [String] {
        switch self {
        case .dreamy:  return ["#FF8AD1", "#A855F7"]
        case .recap:   return ["#FF9F0A", "#FF375F"]
        case .energy:  return ["#FFD60A", "#FF453A"]
        case .calm:    return ["#30D158", "#0A84FF"]
        case .sad:     return ["#5E5CE6", "#64D2FF"]
        case .workout: return ["#0A84FF", "#30D158"]
        }
    }

    var baseVector: TrackVector {
        switch self {
        case .dreamy:
            return TrackVector(tempo: 0.20, energy: 0.20, valence: 0.50, acousticness: 0.70, danceability: 0.30, loudness: 0.20)
        case .recap:
            return TrackVector(tempo: 0.80, energy: 0.90, valence: 0.70, acousticness: 0.10, danceability: 0.85, loudness: 0.80)
        case .energy:
            return TrackVector(tempo: 0.75, energy: 0.85, valence: 0.75, acousticness: 0.20, danceability: 0.80, loudness: 0.70)
        case .calm:
            return TrackVector(tempo: 0.25, energy: 0.15, valence: 0.60, acousticness: 0.80, danceability: 0.20, loudness: 0.15)
        case .sad:
            return TrackVector(tempo: 0.30, energy: 0.25, valence: 0.15, acousticness: 0.50, danceability: 0.25, loudness: 0.30)
        case .workout:
            return TrackVector(tempo: 0.85, energy: 0.90, valence: 0.70, acousticness: 0.15, danceability: 0.90, loudness: 0.85)
        }
    }
}

// MARK: - Сигналы обратной связи (ТЗ Раздел 3.5)

enum FeedbackAction: Sendable {
    case skipEarly(percent: Double)  // Пропуск до 30% трека -> вектор вычитается
    case listenThrough               // Дослушан > 80% -> вектор приближается
    case like                        // Поставлен лайк -> сильный позитивный сдвиг
    case dislike                     // Дизлайк -> исключение из сессии
}

// MARK: - Движок Mood Radio Engine (ТЗ Разделы 2, 3, 5)

@Observable
@MainActor
final class MoodRadioEngine {
    static let shared = MoodRadioEngine()

    // Текущее активное состояние сессии
    private(set) var activeMood: MoodPreset? = nil
    private(set) var sessionVector: TrackVector = MoodPreset.dreamy.baseVector
    private(set) var queue: [Track] = []
    private(set) var recentPlayedTracks: [Track] = []
    private(set) var playedTrackIDs: Set<UUID> = []
    private(set) var playedArtistHistory: [String] = []

    // Веса адаптации Re-seeding (ТЗ 3.5: alpha, beta, gamma)
    private let alpha: Double = 0.50  // Вес базового пресета настроения
    private let beta: Double = 0.30   // Вес скользящего среднего сыгранных треков
    private let gamma: Double = 0.20  // Вес сигналов обратной связи (лайки/скипы)

    private var isGenerating = false

    private static let keyMoodPlayed = "mood.played_ids"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.keyMoodPlayed) ?? []
        self.playedTrackIDs = Set(saved.compactMap { UUID(uuidString: $0) })
    }

    private func rememberPlayed(_ track: Track) {
        playedTrackIDs.insert(track.id)
        playedArtistHistory.append(track.artist)
        recentPlayedTracks.append(track)
        let yId = PlayerCore.yandexTrackID(from: track)
        if !yId.isEmpty {
            YandexMusicService.shared.remember(key: yId, artist: track.artist, ymTrackId: yId)
        }
        let idStrings = Array(playedTrackIDs.suffix(200).map { $0.uuidString })
        UserDefaults.standard.set(idStrings, forKey: Self.keyMoodPlayed)
    }

    // MARK: - API: Старт радио по настроению (POST /mood/start)

    func start(mood: MoodPreset) {
        activeMood = mood
        sessionVector = mood.baseVector
        queue.removeAll()
        recentPlayedTracks.removeAll()
        playedArtistHistory.removeAll()

        // 1. Быстрый сбор свежих треков без повторов
        let initialPool = getCandidatePool(for: mood)
        let sequenced = sequenceCandidates(initialPool, targetVector: sessionVector, count: 20)

        if let first = sequenced.first {
            queue = sequenced
            PlayerCore.shared.play(first, newQueue: queue)
            rememberPlayed(first)
        }

        // 2. Асинхронно дозапрашиваем официальную станцию Яндекса под это настроение (например, activity:workout)
        Task {
            let stationId = stationIdForMood(mood)
            let ym = YandexMusicService.shared
            let rotorTracks = await ym.buildWaveQueue(stationId: stationId, target: 30)
            let unplayed = rotorTracks.filter { !ym.isRecentlyPlayed(ymTrackId: $0.id) }
            let picked = unplayed.isEmpty ? rotorTracks.shuffled() : unplayed
            let converted = picked.map { $0.toTrack() }.filter { !self.playedTrackIDs.contains($0.id) }

            // Сначала подтягиваем уже измеренный анализ (BPM/тональность/энергия) из кэша,
            // чтобы ранжировать по реальным числам, а не по словам в названии трека.
            await AutoMixAnalysisSnapshot.shared.refreshFromCache(converted)

            let freshSequenced = self.sequenceCandidates(converted, targetVector: self.sessionVector, count: 25)
            guard !freshSequenced.isEmpty else { return }

            if self.queue.isEmpty {
                self.queue = freshSequenced
                if let first = freshSequenced.first {
                    PlayerCore.shared.play(first, newQueue: freshSequenced)
                    self.rememberPlayed(first)
                }
            } else {
                self.queue.append(contentsOf: freshSequenced)
                PlayerCore.shared.appendToQueue(freshSequenced)
            }
        }
    }

    // MARK: - API: Сигнал обратной связи (POST /mood/feedback)

    func recordFeedback(track: Track, action: FeedbackAction) {
        guard let mood = activeMood else { return }

        let trackVector = extractVector(for: track)

        switch action {
        case .skipEarly(let pct):
            // Skip до 30%: отдаляемся от вектора трека
            if pct <= 0.35 {
                sessionVector = sessionVector.applyingDelta(trackVector, weight: 0.18, positive: false)
                // Удаляем похожие треки этого артиста из ближайшей очереди
                queue.removeAll { $0.artist == track.artist && $0.id != track.id }
            }

        case .listenThrough:
            // Дослушан > 80%: притягиваемся
            sessionVector = sessionVector.applyingDelta(trackVector, weight: 0.15, positive: true)
            UserTasteEngine.shared.recordPlayback(track: track, listenedSeconds: track.duration * 0.85, totalDuration: track.duration)

        case .like:
            // Лайк: сильное притяжение
            sessionVector = sessionVector.applyingDelta(trackVector, weight: 0.28, positive: true)
            UserTasteEngine.shared.recordLike(track: track)

        case .dislike:
            // Дизлайк: немедленно удаляем из очереди
            queue.removeAll { $0.id == track.id }
            UserTasteEngine.shared.recordDislike(track: track)
        }

        // Пересчет сессионного вектора со скользящим средним
        reseedSessionVector(basePreset: mood)

        // Проверяем запас треков в очереди
        Task {
            await ensureSufficientQueue()
        }
    }

    // MARK: - API: Получить следующий трек (GET /mood/next)

    func nextTrack() -> Track? {
        guard !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        playedTrackIDs.insert(next.id)
        playedArtistHistory.append(next.artist)
        recentPlayedTracks.append(next)
        if recentPlayedTracks.count > 10 {
            recentPlayedTracks.removeFirst()
        }

        Task {
            await ensureSufficientQueue()
        }
        return next
    }

    // MARK: - Re-seeding адаптация вектора (ТЗ 3.5)

    private func reseedSessionVector(basePreset: MoodPreset) {
        guard !recentPlayedTracks.isEmpty else { return }

        // Вычисляем скользящее среднее последних N сыгранных треков
        var avgTempo: Double = 0
        var avgEnergy: Double = 0
        var avgValence: Double = 0
        var avgAcoustic: Double = 0
        var avgDance: Double = 0
        var avgLoud: Double = 0
        let count = Double(recentPlayedTracks.count)

        for t in recentPlayedTracks {
            let vec = extractVector(for: t)
            avgTempo += vec.tempo
            avgEnergy += vec.energy
            avgValence += vec.valence
            avgAcoustic += vec.acousticness
            avgDance += vec.danceability
            avgLoud += vec.loudness
        }

        let movingAvg = TrackVector(
            tempo: avgTempo / count,
            energy: avgEnergy / count,
            valence: avgValence / count,
            acousticness: avgAcoustic / count,
            danceability: avgDance / count,
            loudness: avgLoud / count
        )

        // new_vector = alpha * basePreset + beta * movingAvg + gamma * currentSessionVector
        let blended = TrackVector(
            tempo: alpha * basePreset.baseVector.tempo + beta * movingAvg.tempo + gamma * sessionVector.tempo,
            energy: alpha * basePreset.baseVector.energy + beta * movingAvg.energy + gamma * sessionVector.energy,
            valence: alpha * basePreset.baseVector.valence + beta * movingAvg.valence + gamma * sessionVector.valence,
            acousticness: alpha * basePreset.baseVector.acousticness + beta * movingAvg.acousticness + gamma * sessionVector.acousticness,
            danceability: alpha * basePreset.baseVector.danceability + beta * movingAvg.danceability + gamma * sessionVector.danceability,
            loudness: alpha * basePreset.baseVector.loudness + beta * movingAvg.loudness + gamma * sessionVector.loudness
        )

        sessionVector = blended
    }

    // MARK: - Файловый и сетевой сбор кандидатов (Candidate Retrieval)

    private func getCandidatePool(for mood: MoodPreset) -> [Track] {
        var pool: [Track] = []
        let ym = YandexMusicService.shared

        // 1. Локальная библиотека: отбираем ТОЛЬКО еще не игравшие треки под вектор настроения
        let localTracks = LibraryStore.shared.tracks.filter { track in
            let yId = PlayerCore.yandexTrackID(from: track)
            return !playedTrackIDs.contains(track.id) &&
                   !ym.isRecentlyPlayed(ymTrackId: yId) &&
                   extractVector(for: track).cosineSimilarity(to: mood.baseVector) >= 0.70
        }
        pool.append(contentsOf: localTracks.shuffled())

        // 2. Треки из кэша чартов, подходящие под вектор
        let ymTracks = ym.chartCache.map { $0.toTrack() }.filter { track in
            let yId = PlayerCore.yandexTrackID(from: track)
            return !playedTrackIDs.contains(track.id) &&
                   !ym.isRecentlyPlayed(ymTrackId: yId) &&
                   extractVector(for: track).cosineSimilarity(to: mood.baseVector) >= 0.68
        }
        pool.append(contentsOf: ymTracks.shuffled())

        return pool.shuffled()
    }

    // MARK: - Ранжирование, Diversity & Sequencing Filter (ТЗ 3.3, 3.4)

    private func sequenceCandidates(_ candidates: [Track], targetVector: TrackVector, count: Int) -> [Track] {
        guard !candidates.isEmpty else { return [] }

        // 1. Вычисляем cosine similarity для всех кандидатов
        var scored: [(track: Track, sim: Double)] = candidates.compactMap { track in
            if UserTasteEngine.shared.isDisliked(track: track) { return nil }
            let vec = extractVector(for: track)
            let sim = vec.cosineSimilarity(to: targetVector)
            return (track, sim)
        }

        // Сортировка по убыванию близости к вектору настроения
        scored.sort { $0.sim > $1.sim }

        var result: [Track] = []
        var recentArtists = Array(playedArtistHistory.suffix(5))
        var candidateIdx = 0

        // 2. Построение очереди с анти-повтором артистов и 12% Explore-квотой
        while result.count < count && candidateIdx < scored.count {
            // Explore-квота: 12% треков берем чуть дальше из пула для музыкального кругозора
            let isExplore = (Double.random(in: 0...1) < 0.12) && (scored.count > 15)
            let pickIndex = isExplore ? Int.random(in: min(15, scored.count - 1)..<scored.count) : candidateIdx

            let item = scored[pickIndex]
            let artist = item.track.artist

            // Проверка: не повторять исполнителя чаще, чем раз в 5 треков
            let artistCountRecent = recentArtists.filter { $0 == artist }.count
            if artistCountRecent == 0 || candidateIdx > scored.count / 2 {
                result.append(item.track)
                recentArtists.append(artist)
                if recentArtists.count > 5 { recentArtists.removeFirst() }
            }

            candidateIdx += 1
        }

        return result
    }

    // MARK: - Бесконечная фоновая догрузка треков

    private func ensureSufficientQueue() async {
        guard !isGenerating, let mood = activeMood else { return }
        guard queue.count < 6 else { return }

        isGenerating = true
        defer { isGenerating = false }

        // Дозапрашиваем новую волну треков из станции Яндекс Музыки
        let stationId = stationIdForMood(mood)
        let freshRotorTracks = (try? await YandexMusicService.shared.getStationTracks(stationId: stationId)) ?? []
        let converted = freshRotorTracks.map { $0.toTrack() }.filter { !playedTrackIDs.contains($0.id) }

        // Подтягиваем измеренный анализ из кэша перед ранжированием новой волны
        await AutoMixAnalysisSnapshot.shared.refreshFromCache(converted)

        let sequenced = sequenceCandidates(converted, targetVector: sessionVector, count: 12)
        if !sequenced.isEmpty {
            queue.append(contentsOf: sequenced)
            PlayerCore.shared.appendToQueue(sequenced)
        }
    }

    private func stationIdForMood(_ mood: MoodPreset) -> String {
        switch mood {
        case .dreamy:  return "mood:calm"
        case .recap:   return "genre:pop"
        case .energy:  return "activity:party"
        case .calm:    return "mood:calm"
        case .sad:     return "mood:sad"
        case .workout: return "activity:workout"
        }
    }

    // MARK: - Извлечение вектора трека (Feature Extractor)

    /// Вектор трека для ранжирования. Главный источник - РЕАЛЬНЫЙ измеренный
    /// анализ AutoMix (BPM, тональность, энергия, уверенность бита, кривая
    /// энергии); эвристика по названию остаётся только резервом для треков,
    /// которые ещё ни разу не анализировались.
    func extractVector(for track: Track) -> TrackVector {
        let heuristic = heuristicVector(for: track)

        if let analysis = AutoMixAnalysisSnapshot.shared.analysis(for: track) {
            return TrackVector.measured(analysis, fallback: heuristic)
        }

        // Анализа ещё нет в зеркале: без блокировки спрашиваем кэш на будущее
        // и возвращаем эвристику сейчас.
        AutoMixAnalysisSnapshot.shared.requestCacheRefresh(for: track)
        return heuristic
    }

    /// Резервная оценка по названию и длительности - используется только пока
    /// реальный анализ трека недоступен.
    private func heuristicVector(for track: Track) -> TrackVector {
        let titleLower = track.title.lowercased()

        // Эвристический базовый анализ по длительности и названию/жанру
        var tempo: Double = 0.50
        var energy: Double = 0.50
        var valence: Double = 0.50
        var acousticness: Double = 0.30

        if titleLower.contains("remix") || titleLower.contains("club") || titleLower.contains("dance") {
            tempo = 0.85
            energy = 0.90
            valence = 0.75
            acousticness = 0.05
        } else if titleLower.contains("acoustic") || titleLower.contains("live") || titleLower.contains("piano") {
            tempo = 0.30
            energy = 0.20
            valence = 0.40
            acousticness = 0.90
        } else if titleLower.contains("chill") || titleLower.contains("calm") || titleLower.contains("meditation") {
            tempo = 0.25
            energy = 0.15
            valence = 0.60
            acousticness = 0.70
        } else if titleLower.contains("sad") || titleLower.contains("грустн") || titleLower.contains("слез") {
            tempo = 0.35
            energy = 0.30
            valence = 0.15
            acousticness = 0.50
        }

        if track.duration > 0 && track.duration < 150 {
            // Короткие динамичные треки обычно выше темпом
            tempo = min(1.0, tempo + 0.10)
        }

        return TrackVector(
            tempo: tempo,
            energy: energy,
            valence: valence,
            acousticness: acousticness,
            danceability: energy * 0.9,
            loudness: energy * 0.85
        )
    }
}

extension YandexMusicService.YMTrackItem {
    func toTrack() -> Track {
        YandexMusicService.shared.convertToTrack(self)
    }
}
