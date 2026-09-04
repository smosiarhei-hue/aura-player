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

// MARK: - AutoMix DJ Engine (AI & DSP Transition Executor)

@Observable
@MainActor
final class AutoMixDJEngine {
    static let shared = AutoMixDJEngine()

    var isTransitionActive: Bool = false
    var transitionProgress: Double = 0.0
    var activeStrategyName: String = "BASS_SWAP"
    var activePlan: TransitionPlan? = nil
    var statusBadge: String? = nil
    var currentBPM: Double = 0

    private init() {}

    /// Execute the plan's action envelopes (TZ Section 15): piecewise ramps
    /// over the plan's keyframes for one lane/parameter. A keyframe
    /// (time, value, duration) means "starting at `time`, ramp to `value`
    /// over `duration` seconds". `defaultValue` is the level before the first
    /// keyframe begins - the source plays at full level until told otherwise,
    /// the target starts silent - which keeps half-specified envelopes from
    /// jumping to their final value on the very first tick. Returns nil when
    /// the plan carries no keyframes for that pair, so the caller keeps its
    /// own fallback curves.
    nonisolated static func sampleEnvelope(
        _ actions: [TransitionAction],
        target: String,
        parameter: String,
        at time: Double,
        defaultValue: Float? = nil
    ) -> Float? {
        let frames = actions
            .filter {
                $0.target == target && $0.parameter == parameter
                    && $0.time.isFinite && $0.value.isFinite && $0.duration.isFinite
            }
            .sorted { $0.time < $1.time }
        guard let first = frames.first else { return nil }

        var value = Double(defaultValue ?? Float(first.value))
        for (index, frame) in frames.enumerated() where frame.time <= time {
            let segment: Double = frame.duration > 0.001
                ? min(1, max(0, (time - frame.time) / frame.duration))
                : 1
            let startValue: Double = value
            var endValue: Double = frame.value

            // Several AutoMix plans use an explicit silent keyframe at t=0 for
            // the incoming lane, then the next keyframe says where that lane
            // should be by the middle/end of the blend. The old executor ramped
            // from 0 to 0 during the first segment, so the next track stayed
            // muted for most of the transition and then jumped to full volume
            // when `completeTransition` promoted the lane. Interpret that
            // silent hold as "ramp toward the next incoming-volume keyframe".
            if target == "target",
               parameter == "volume",
               index + 1 < frames.count,
               abs(endValue - startValue) < 0.0001,
               frames[index + 1].time > frame.time {
                endValue = Double(frames[index + 1].value)
            }

            // The promoted lane becomes the main player at the end of the
            // transition. Make sure the last incoming-volume ramp really lands
            // on unity, otherwise the hand-off sounds like a sudden volume jump.
            if target == "target",
               parameter == "volume",
               index == frames.count - 1,
               endValue < 0.999 {
                endValue = 1.0
            }

            let delta: Double = endValue - startValue
            value = startValue + delta * segment
        }

        if target == "target", parameter == "volume" {
            // User-device logs showed a real ENERGY_BLEND transition, but it
            // still sounded like the old hand-off: the incoming lane was too
            // quiet until the final promotion, then it felt like it jumped to
            // maximum. For AutoMix we now enforce an audible equal-power floor
            // across the whole planned window. This keeps AI/local envelopes,
            // but prevents any plan from hiding the next track until the end.
            let total = frames.reduce(0.0) { max($0, $1.time + max(0, $1.duration)) }
            if total > 0.001 {
                let p = min(1.0, max(0.0, time / total))
                let equalPower = sin(p * (.pi / 2))
                let audibleFloor = 0.16 + equalPower * 0.84
                value = max(value, audibleFloor)
            }
            value = min(1.0, max(0.0, value))
        }

        if parameter == "reverb", value > 0 {
            // Wet/dry values below ~30% were too subtle on phone speakers and
            // made the transition feel like a plain fade. Keep it bounded but
            // intentionally audible for the UI AutoMix test.
            value = min(1.0, value * 2.2 + 0.15)
        }

        return Float(value)
    }

    func computeVolumesAndEQ(
        progress: Double,
        strategy: TransitionStrategy
    ) -> (outgoingVol: Float, incomingVol: Float, outgoingBassCutDB: Float, incomingBassGainDB: Float, filterCutoff: Float) {
        let p = max(0.0, min(1.0, progress))

        // 1. Equal-Power Cosine Crossfade Curve (Section 28)
        var outVol = Float(cos(p * (.pi / 2)))
        var inVol = Float(sin(p * (.pi / 2)))

        var outBassCut: Float = 0
        var inBassGain: Float = 0
        var filterCutoff: Float = 1.0

        switch strategy {
        case .DROP_SWITCH, .HARD_CUT:
            // High energy hold on outgoing track, then quick punchy hand-off to incoming track.
            // Absolutely NO SILENCE DIP: incoming track is audible from the start and hits 100% on the drop!
            let switchPoint = 0.50
            if p < switchPoint {
                outVol = 1.0
                let rampIn = Float(p / switchPoint)
                inVol = Float(sin(Double(rampIn) * (.pi / 2))) * 0.70
            } else {
                let exitP = Float((p - switchPoint) / (1.0 - switchPoint))
                outVol = max(0.0, 1.0 - (exitP * exitP))
                inVol = 0.70 + (0.30 * exitP)
            }
            if p > switchPoint {
                outBassCut = -24.0 * Float((p - switchPoint) / (1.0 - switchPoint))
            }

        case .VOCAL_CUT:
            // Smooth vocal fade-out crossfade
            outVol = Float(cos(p * (.pi / 2)))
            inVol = Float(sin(p * (.pi / 2)))
            if p > 0.40 {
                outBassCut = -20.0 * Float((p - 0.40) / 0.60)
            }

        case .BASS_SWAP, .BEAT_MATCH_EQ:
            if p > 0.18 {
                let bassP = Float((p - 0.18) / 0.82)
                outBassCut = -28.0 * (bassP * bassP)
            }
            if p < 0.32 {
                let inP = Float(p / 0.32)
                inBassGain = -22.0 * (1.0 - inP)
            } else {
                inBassGain = 0.0
            }

        case .FILTER_TRANSITION:
            filterCutoff = max(0.1, Float(1.0 - p))
            outBassCut = Float(p) * -32.0
            inBassGain = Float(1.0 - p) * -12.0
            outVol = Float(cos(p * (.pi / 2)))
            inVol = Float(sin(p * (.pi / 2)))

        case .ENERGY_BLEND, .BUILDUP_TO_DROP:
            if p > 0.35 {
                outBassCut = Float((p - 0.35) / 0.65) * -30.0
            }
            if p < 0.25 {
                inBassGain = -18.0 * (1.0 - Float(p / 0.25))
            }
            outVol = Float(cos(p * (.pi / 2)))
            inVol = Float(sin(p * (.pi / 2)))

        case .ECHO_OUT:
            outBassCut = Float(p) * -20.0
            if p > 0.50 {
                outVol = outVol * Float(max(0.1, 1.0 - (p - 0.50) * 1.5))
            }

        case .SILENCE_TRIM, .SIMPLE_CROSSFADE, .BEAT_MATCH, .LOOP_TRANSITION, .INSTRUMENTAL_OVERLAY, .NONE:
            if p > 0.40 {
                outBassCut = Float((p - 0.40) / 0.60) * -16.0
            }
        }

        return (outVol, inVol, outBassCut, inBassGain, filterCutoff)
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
