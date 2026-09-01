import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transition Mode

enum TransitionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automix = "AutoMix (DJ-сведение)"
    case crossfade = "Кроссфейд"
    case gapless = "Gapless (Без пауз)"
    case off = "Выключено"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .automix:
            return "Умный анализ концовки, срез басов уходящего трека (Bass-Swap), обрезка тишины и адаптивный тайминг как в Apple Music."
        case .crossfade:
            return "Классическое плавное наложение звука по фиксированному времени."
        case .gapless:
            return "Мгновенное переключение следующего трека без пауз и задержек."
        case .off:
            return "Стандартное раздельное воспроизведение треков."
        }
    }
}

// MARK: - AutoMix DJ Transition Style

enum DJTransitionStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case adaptiveAI = "AutoMix AI"
    case bassSwap = "Bass-Swap DJ"
    case filterSweep = "Filter Sweep"
    case smoothDissolve = "Harmonic Dissolve"
    case quickDrop = "Drop on Beat"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .adaptiveAI: return "AutoMix AI (Умный DJ)"
        case .bassSwap: return "Bass-Swap (Срез басов DJ)"
        case .filterSweep: return "Filter Sweep (Фильтр-переход)"
        case .smoothDissolve: return "Harmonic Dissolve (Плавное сведение)"
        case .quickDrop: return "Drop on Beat (Мгновенный дроп)"
        }
    }

    var icon: String {
        switch self {
        case .adaptiveAI: return "sparkles"
        case .bassSwap: return "waveform.badge.magnifyingglass"
        case .filterSweep: return "slider.horizontal.3"
        case .smoothDissolve: return "waveform"
        case .quickDrop: return "bolt.fill"
        }
    }

    var description: String {
        switch self {
        case .adaptiveAI:
            return "ИИ анализирует концовку трека, динамику баса и структуру, подбирая идеальный момент и кривую перехода."
        case .bassSwap:
            return "Классический DJ-прием: плавный срез низких частот уходящего трека для чистого входа баса без грязи."
        case .filterSweep:
            return "Мягкий срез средних и высоких частот с фильтрацией и растворением в следующий трек."
        case .smoothDissolve:
            return "Плавное гармоническое логарифмическое наложение с сохранением вокала."
        case .quickDrop:
            return "Быстрый переход прямо в сильную долю следующей песни (Drop on Beat)."
        }
    }
}

// MARK: - Track Cue Profile (Анализ трека перед сведением)

struct TrackCueProfile: Sendable, Codable {
    var outroStartOffset: Double
    var outroDuration: Double
    var introDropOffset: Double
    var detectedBPM: Double?
    var silenceTailDuration: Double
    var recommendedStyle: DJTransitionStyle

    static func computeProfile(for track: Track, duration: Double) -> TrackCueProfile {
        let totalDur = max(duration, track.duration)
        let outroDur: Double
        if totalDur > 120 { outroDur = 6.0 }
        else if totalDur > 60 { outroDur = 4.5 }
        else if totalDur > 30 { outroDur = 3.0 }
        else { outroDur = 1.5 }

        let style: DJTransitionStyle
        let titleLower = (track.title + " " + track.artist).lowercased()
        if titleLower.contains("remix") || titleLower.contains("club") || titleLower.contains("edit") || titleLower.contains("dance") {
            style = .bassSwap
        } else if titleLower.contains("tune") || titleLower.contains("piano") || titleLower.contains("chill") || titleLower.contains("acoustic") {
            style = .smoothDissolve
        } else {
            style = totalDur > 90 ? .bassSwap : .smoothDissolve
        }

        return TrackCueProfile(
            outroStartOffset: max(0, totalDur - outroDur),
            outroDuration: outroDur,
            introDropOffset: 0.05,
            detectedBPM: 120.0,
            silenceTailDuration: 0.15,
            recommendedStyle: style
        )
    }
}

// MARK: - AutoMix Transition Style (Legacy Compatibility)

enum AutoMixStyle: Sendable {
    case bassSwapBlend(duration: Double)
    case quickDrop(duration: Double)
    case fadeOut(duration: Double)
}

// MARK: - AutoMix DJ Engine (Профессиональное сведение)

@Observable
@MainActor
final class AutoMixDJEngine {
    static let shared = AutoMixDJEngine()

    var isTransitionActive: Bool = false
    var transitionProgress: Double = 0.0
    var activeStyle: DJTransitionStyle = .adaptiveAI
    var statusBadge: String? = nil

    var djStyle: DJTransitionStyle = .adaptiveAI {
        didSet { UserDefaults.standard.set(djStyle.rawValue, forKey: "automix.djStyle") }
    }
    var bassSwapEnabled: Bool = true {
        didSet { UserDefaults.standard.set(bassSwapEnabled, forKey: "automix.bassSwap") }
    }
    var trimSilenceEnabled: Bool = true {
        didSet { UserDefaults.standard.set(trimSilenceEnabled, forKey: "automix.trimSilence") }
    }
    var maxTransitionDuration: Double = 6.0 {
        didSet { UserDefaults.standard.set(maxTransitionDuration, forKey: "automix.maxDuration") }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "automix.djStyle"),
           let style = DJTransitionStyle(rawValue: saved) {
            djStyle = style
        }
        if UserDefaults.standard.object(forKey: "automix.bassSwap") != nil {
            bassSwapEnabled = UserDefaults.standard.bool(forKey: "automix.bassSwap")
        }
        if UserDefaults.standard.object(forKey: "automix.trimSilence") != nil {
            trimSilenceEnabled = UserDefaults.standard.bool(forKey: "automix.trimSilence")
        }
        let dur = UserDefaults.standard.double(forKey: "automix.maxDuration")
        if dur > 0 { maxTransitionDuration = dur }
    }

    func planTransition(
        outgoing: Track,
        outgoingDuration: Double,
        incoming: Track,
        mode: TransitionMode
    ) -> (cueTime: Double, blendDuration: Double, style: DJTransitionStyle) {
        guard mode != .off else {
            return (outgoingDuration, 0, .quickDrop)
        }
        if mode == .gapless {
            return (max(0, outgoingDuration - 0.08), 0.08, .quickDrop)
        }
        if mode == .crossfade {
            let dur = UserDefaults.standard.double(forKey: "player.crossfadeDuration")
            let effectiveDur = dur > 0 ? dur : 4.0
            let cue = max(0, outgoingDuration - effectiveDur)
            return (cue, effectiveDur, .smoothDissolve)
        }

        let profile = TrackCueProfile.computeProfile(for: outgoing, duration: outgoingDuration)
        let chosenStyle: DJTransitionStyle = (djStyle == .adaptiveAI) ? profile.recommendedStyle : djStyle
        let targetDur = min(profile.outroDuration, maxTransitionDuration)
        let cue = max(0, outgoingDuration - targetDur)

        return (cue, targetDur, chosenStyle)
    }

    func computeVolumesAndEQ(
        progress: Double,
        style: DJTransitionStyle
    ) -> (outgoingVol: Float, incomingVol: Float, outgoingBassCutDB: Float, incomingBassGainDB: Float) {
        let p = max(0.0, min(1.0, progress))

        // Equal-Power Transition with early incoming sound presence
        let outVol = Float(cos(p * .pi / 2))
        let inVol = Float(pow(sin(p * .pi / 2), 0.75))

        var outBassCut: Float = 0
        var inBassGain: Float = 0

        switch style {
        case .bassSwap, .adaptiveAI:
            if bassSwapEnabled {
                if p > 0.15 {
                    let bassP = (p - 0.15) / 0.85
                    outBassCut = Float(bassP) * -22.0
                }
                inBassGain = 0
            }
        case .filterSweep:
            outBassCut = Float(p) * -28.0
        case .smoothDissolve:
            outBassCut = Float(p) * -6.0
        case .quickDrop:
            outBassCut = 0
        }

        return (outVol, inVol, outBassCut, inBassGain)
    }
}

// MARK: - Track Model

struct Track: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var fileName: String
    var relativePath: String = ""
    var title: String
    var artist: String
    var album: String
    var duration: Double = 0
    var artworkSeed: Int = 0
    var colorsHex: [String] = []
    var hasEmbeddedArtwork: Bool = false
    var isFavorite: Bool = false
    var addedAt: Date = Date()
    var isStream: Bool = false
    var streamUrlString: String? = nil
    var coverURL: String? = nil
    var lyricsText: String? = nil

    var url: URL {
        if isStream, let str = streamUrlString, let u = URL(string: str) {
            return u
        }
        if !relativePath.isEmpty {
            return documentsDirectoryURL().appendingPathComponent(relativePath)
        }
        return documentsDirectoryURL().appendingPathComponent(fileName)
    }

    var palette: [Color] {
        let parsed = colorsHex.compactMap { Color(hex: $0) }
        return parsed.isEmpty ? Palette.seeded(artworkSeed).colors : parsed
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id || (lhs.fileName == rhs.fileName && !lhs.fileName.isEmpty)
    }
}

// MARK: - Playlist Model

struct Playlist: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var trackIds: [UUID] = []
    var coverGradient: [String] = ["#FF455B", "#9333EA"]
}

// MARK: - Repeat / Shuffle

enum RepeatMode: Int, Codable, CaseIterable, Sendable {
    case off = 0, all = 1, one = 2

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var title: String {
        switch self {
        case .off: return "Выкл"
        case .all: return "Все"
        case .one: return "Один"
        }
    }
}

// MARK: - EQ Presets

struct EQPreset: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let gains: [Float]
}

enum EQPresets {
    static let flat = EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

    static let all: [EQPreset] = [
        flat,
        EQPreset(name: "Rock",       gains: [ 5,  4,  2, -1, -2,  0,  2,  4,  5,  5]),
        EQPreset(name: "Pop",        gains: [-1,  1,  3,  4,  3,  0, -1, -1,  1,  2]),
        EQPreset(name: "Bass Boost", gains: [ 8,  7,  5,  2,  0,  0,  0,  0,  1,  2]),
        EQPreset(name: "Electronic", gains: [ 5,  4,  1,  0, -2,  1,  0,  1,  4,  5]),
        EQPreset(name: "Jazz",       gains: [ 3,  2,  1,  2, -1, -1,  0,  1,  3,  4]),
        EQPreset(name: "Classical",  gains: [ 4,  3,  2,  0, -1, -1,  0,  2,  3,  4]),
        EQPreset(name: "Vocal",      gains: [-2, -1,  0,  2,  4,  4,  3,  1,  0, -1]),
        EQPreset(name: "Acoustic",   gains: [ 3,  2,  1,  1, -1, -1, -2, -2, -1,  0])
    ]
}

// MARK: - Palette

struct Palette {
    let colors: [Color]

    static func seeded(_ seed: Int) -> Palette {
        var gen = SeededGenerator(seed: UInt64(truncatingIfNeeded: Int64(seed &+ 7331)))
        let base = Double.random(in: 0...1, using: &gen)
        var result: [Color] = []
        let offsets: [Double] = [0.0, 0.08, -0.12, 0.45, -0.28]
        for offset in offsets {
            let hue = (base + offset).truncatingRemainder(dividingBy: 1.0)
            let sat = Double.random(in: 0.65...0.90, using: &gen)
            let bri = Double.random(in: 0.50...0.80, using: &gen)
            result.append(Color(hue: hue < 0 ? hue + 1.0 : hue, saturation: sat, brightness: bri))
        }
        return Palette(colors: result)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Global Directory Helpers

nonisolated func documentsDirectoryURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
}

nonisolated func musicDirectoryURL() -> URL {
    let dir = documentsDirectoryURL().appendingPathComponent("Music", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

nonisolated func artworkCacheDirectoryURL() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let dir = caches.appendingPathComponent("ArtworkCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Color Hex Conversion

extension Color {
    init?(hex: String) {
        var value: String = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    var hexString: String {
        guard let comps = UIColor(self).cgColor.components, comps.count >= 3 else { return "#888888" }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
