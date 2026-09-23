import Foundation
import SwiftUI
import Observation

// MARK: - Модели настроек «Моей волны»

enum WaveDiversity: String, CaseIterable, Identifiable, Sendable {
    case defaultMode = "default"
    case favorite = "favorite"
    case discover = "discover"
    case popular = "popular"

    static let defaultDiversity: WaveDiversity = .defaultMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultMode: return "Обычное"
        case .favorite:    return "Любимое"
        case .discover:    return "Незнакомое"
        case .popular:     return "Популярное"
        }
    }

    var subtitle: String {
        switch self {
        case .defaultMode: return "Баланс знакомого и нового"
        case .favorite:    return "Треки любимых артистов"
        case .discover:    return "Новые имена и открытия"
        case .popular:     return "Главные хиты и тренды"
        }
    }

    var icon: String {
        switch self {
        case .defaultMode: return "waveform"
        case .favorite:    return "heart.fill"
        case .discover:    return "sparkles"
        case .popular:     return "flame.fill"
        }
    }

    var rotorValue: String { rawValue }
}

enum WaveLanguage: String, CaseIterable, Identifiable, Sendable {
    case any = "any"
    case russian = "russian"
    case foreign = "not-russian"
    case instrumental = "without-words"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any:          return "Любой"
        case .russian:      return "Русский"
        case .foreign:      return "Иностранный"
        case .instrumental: return "Без слов"
        }
    }

    var icon: String {
        switch self {
        case .any:          return "globe"
        case .russian:      return "character.ru"
        case .foreign:      return "globe.europe.africa.fill"
        case .instrumental: return "pianokeys"
        }
    }

    var rotorValue: String { rawValue }
}

enum WaveMoodEnergy: String, CaseIterable, Identifiable, Sendable {
    case all = "all"
    case active = "active"
    case calm = "calm"
    case fun = "fun"
    case sad = "sad"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:    return "Любое"
        case .active: return "Бодрое"
        case .calm:   return "Спокойное"
        case .fun:    return "Радостное"
        case .sad:    return "Погрустить"
        }
    }

    var icon: String {
        switch self {
        case .all:    return "sparkles"
        case .active: return "bolt.fill"
        case .calm:   return "leaf.fill"
        case .fun:    return "face.smiling.fill"
        case .sad:    return "cloud.rain.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .all:    return [Color.cyan, Color.purple]
        case .active: return [Color.orange, Color.red]
        case .calm:   return [Color.green, Color.teal]
        case .fun:    return [Color.yellow, Color.pink]
        case .sad:    return [Color.blue, Color.purple]
        }
    }

    var rotorValue: String { rawValue }
}

// MARK: - Центральное хранилище настроек волны

@Observable
final class WaveSettingsStore: @unchecked Sendable {
    static let shared = WaveSettingsStore()

    private let defaults = UserDefaults.standard
    private let keyDiversity = "sonivo_wave_diversity_v1"
    private let keyLanguage = "sonivo_wave_language_v1"
    private let keyMoodEnergy = "sonivo_wave_mood_energy_v1"

    var diversity: WaveDiversity {
        didSet {
            defaults.set(diversity.rawValue, forKey: keyDiversity)
            notifySettingsChanged()
        }
    }

    var language: WaveLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: keyLanguage)
            notifySettingsChanged()
        }
    }

    var moodEnergy: WaveMoodEnergy {
        didSet {
            defaults.set(moodEnergy.rawValue, forKey: keyMoodEnergy)
            notifySettingsChanged()
        }
    }

    init() {
        let savedDiversity = defaults.string(forKey: keyDiversity).flatMap(WaveDiversity.init(rawValue:)) ?? .defaultMode
        let savedLanguage = defaults.string(forKey: keyLanguage).flatMap(WaveLanguage.init(rawValue:)) ?? .any
        let savedMood = defaults.string(forKey: keyMoodEnergy).flatMap(WaveMoodEnergy.init(rawValue:)) ?? .all

        self.diversity = savedDiversity
        self.language = savedLanguage
        self.moodEnergy = savedMood
    }

    private func notifySettingsChanged() {
        Task { @MainActor in
            YandexMusicService.shared.sendWaveSettingsChange()
        }
    }

    /// Бесшовно пересобирает хвост очереди воспроизведения «Моей волны» под новые настройки,
    /// не прерывая текущий играющий трек.
    @MainActor
    func reseedActiveWaveQueue() async -> Bool {
        guard let current = PlayerCore.shared.currentTrack else { return false }
        let service = YandexMusicService.shared
        let stationId = service.waveMoodStationId

        var tracks = await service.buildWaveQueue(stationId: stationId, target: 45)
        if tracks.isEmpty { tracks = (try? await service.getChart()) ?? [] }
        guard !tracks.isEmpty else { return false }

        let filtered = tracks
            .map { service.convertToTrack($0) }
            .filter { !UserTasteEngine.shared.isDisliked(track: $0) && $0.id != current.id }

        let ranked = UserTasteEngine.shared.filterAndRankWave(tracks: filtered)
        guard !ranked.isEmpty else { return false }

        // Сохраняем текущий трек во главе очереди, а всё следующее плавно заменяем на новые треки
        PlayerCore.shared.queue = [current] + ranked
        return true
    }
}
