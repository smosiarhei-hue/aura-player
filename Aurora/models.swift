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
    var transitionProgress: Double = 0.0 {
        didSet { logTransitionSnapshotIfNeeded() }
    }
    var activeStrategyName: String = "BASS_SWAP"
    var activePlan: TransitionPlan? = nil
    var statusBadge: String? = nil
    var currentBPM: Double = 0
    private var lastTransitionLogBucket: Int = -1

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

            if target == "target",
               parameter == "volume",
               index + 1 < frames.count,
               abs(endValue - startValue) < 0.0001,
               frames[index + 1].time > frame.time {
                endValue = Double(frames[index + 1].value)
            }

            if target == "target",
               parameter == "volume",
               index == frames.count - 1,
               endValue < 0.999 {
                endValue = 1.0
            }

            let delta: Double = endValue - startValue
            value = startValue + delta * segment
        }

        let total = frames.reduce(0.0) { max($0, $1.time + max(0, $1.duration)) }
        if total > 0.001 {
            let p = min(1.0, max(0.0, time / total))

            if target == "target", parameter == "volume" {
                // Make the mashup unmistakable: the incoming lane is quiet at the
                // very first beat, clearly audible by 25-30%, and already near full
                // before the final hand-off. This removes the old "silent until the
                // last millisecond, then jump" effect the device logs exposed.
                let fastP = min(1.0, p / 0.72)
                let equalPower = sin(fastP * (.pi / 2))
                let audibleFloor = 0.06 + equalPower * 0.94
                value = max(value, audibleFloor)
                value = min(1.0, max(0.0, value))
            }

            if target == "source", parameter == "volume" {
                // Do not leave the outgoing track at full volume until the final
                // quarter: start ducking earlier so the blend reads as a DJ move,
                // not a normal track end.
                let shaped: Double
                if p < 0.18 {
                    shaped = 1.0
                } else if p < 0.72 {
                    let q = (p - 0.18) / 0.54
                    shaped = 1.0 - q * 0.48
                } else {
                    let q = (p - 0.72) / 0.28
                    shaped = max(0.0, 0.52 * (1.0 - q))
                }
                value = min(value, shaped)
                value = min(1.0, max(0.0, value))
            }

            if target == "source", parameter == "lowEQ" {
                // Start removing the outgoing bass early; otherwise both songs feel
                // like a plain volume fade and the bass hand-off is inaudible.
                let earlyCut = max(0.04, 1.0 - min(1.0, p / 0.62) * 0.96)
                value = min(value, earlyCut)
            }

            if target == "target", parameter == "lowEQ" {
                // Bring the incoming bass back by the middle, not at the very end.
                let earlyReturn = min(1.0, p / 0.55)
                value = max(value, earlyReturn)
            }
        }

        if parameter == "reverb", value > 0 {
            // Wet/dry values below ~30% were too subtle on phone speakers and made
            // the transition feel like a plain fade. Push reverb into an obvious
            // tail for local AutoMix testing, still bounded to 100%.
            value = min(1.0, value * 2.4 + 0.20)
        }

        return Float(value)
    }

    private func logTransitionSnapshotIfNeeded() {
        guard isTransitionActive else {
            lastTransitionLogBucket = -1
            return
        }

        let p = min(1.0, max(0.0, transitionProgress))
        let bucket: Int
        if p < 0.04 { bucket = 0 }
        else if p < 0.30 { bucket = 25 }
        else if p < 0.55 { bucket = 50 }
        else if p < 0.82 { bucket = 75 }
        else if p < 0.98 { bucket = 95 }
        else { bucket = 100 }

        guard bucket != lastTransitionLogBucket else { return }
        lastTransitionLogBucket = bucket

        let strategy = activePlan?.strategy ?? TransitionStrategy(rawValue: activeStrategyName) ?? .ENERGY_BLEND
        let actions = activePlan?.actions ?? []
        let blendTime = p * max(0.001, activePlan?.leadTime ?? 1.0)
        let base = computeVolumesAndEQ(progress: p, strategy: strategy)

        let sourceVol = AutoMixDJEngine.sampleEnvelope(actions, target: "source", parameter: "volume", at: blendTime, defaultValue: 1.0) ?? base.outgoingVol
        let targetVol = AutoMixDJEngine.sampleEnvelope(actions, target: "target", parameter: "volume", at: blendTime, defaultValue: 0.0) ?? base.incomingVol
        let sourceLow = AutoMixDJEngine.sampleEnvelope(actions, target: "source", parameter: "lowEQ", at: blendTime, defaultValue: 1.0)
        let targetLow = AutoMixDJEngine.sampleEnvelope(actions, target: "target", parameter: "lowEQ", at: blendTime, defaultValue: 0.0)
        let reverb = AutoMixDJEngine.sampleEnvelope(actions, target: "source", parameter: "reverb", at: blendTime, defaultValue: 0.0) ?? 0
        let sourceLowDB = sourceLow.map { max(-30.0, min(0.0, ($0 - 1) * 24.0)) } ?? base.outgoingBassCutDB
        let targetLowDB = targetLow.map { max(-30.0, min(0.0, ($0 - 1) * 24.0)) } ?? base.incomingBassGainDB

        SonivoDiagnostics.log(
            "[AutoMix Tick] \(bucket)% strategy=\(strategy.rawValue) srcVol=\(String(format: "%.2f", sourceVol)) tgtVol=\(String(format: "%.2f", targetVol)) srcLow=\(String(format: "%.1f", sourceLowDB))dB tgtLow=\(String(format: "%.1f", targetLowDB))dB reverb=\(String(format: "%.2f", reverb)) targetStart=\(String(format: "%.2f", activePlan?.targetTrack.startPosition ?? 0))s",
            tag: "AUTOMIX"
        )
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
            // DJ/mashup curve: incoming becomes audible early, outgoing ducks
            // before the final quarter, and the bass hand-off happens in the
            // middle so the transition has a clear shape on phone speakers.
            let fastIn = min(1.0, p / 0.72)
            inVol = max(Float(0.06 + sin(fastIn * (.pi / 2)) * 0.94), inVol)
            if p < 0.18 {
                outVol = 1.0
            } else if p < 0.72 {
                let q = Float((p - 0.18) / 0.54)
                outVol = min(outVol, max(0.52, 1.0 - q * 0.48))
            } else {
                let q = Float((p - 0.72) / 0.28)
                outVol = min(outVol, max(0.0, 0.52 * (1.0 - q)))
            }
            outBassCut = -30.0 * Float(min(1.0, max(0.0, (p - 0.18) / 0.62)))
            inBassGain = -24.0 * Float(max(0.0, 1.0 - min(1.0, p / 0.55)))
            filterCutoff = max(0.15, Float(1.0 - p * 0.85))

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
