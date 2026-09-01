import Foundation

// MARK: - AutoMix analysis model
//
// Result of the offline analysis pass for one local audio file. Everything here
// is Codable so it can be cached on disk and never recomputed for the same file.

nonisolated enum MusicalMode: String, Codable, Sendable {
    case major
    case minor
}

nonisolated struct MusicalKey: Codable, Sendable, Equatable {
    /// 0 = C, 1 = C#/Db, ... 11 = B
    var pitchClass: Int
    var mode: MusicalMode
    /// 0...1 correlation strength of the winning Krumhansl template.
    var confidence: Float

    static let pitchNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    var normalizedPitchClass: Int { ((pitchClass % 12) + 12) % 12 }

    var displayName: String {
        Self.pitchNames[normalizedPitchClass] + (mode == .major ? " maj" : " min")
    }
}

nonisolated struct CuePoint: Codable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case verseEnd
        case chorusEnd
        case breakdownStart
        case preDrop
    }

    let time: TimeInterval
    let kind: Kind
    let confidence: Float
}

nonisolated struct TrackAnalysis: Codable, Sendable {
    /// Bump this when any analyzer changes so cached files are invalidated.
    static let currentVersion = 1

    let trackID: UUID
    var bpm: Double
    /// 0...1 - how clearly the track has a steady beat. Ballads, spoken word
    /// and classical stay low, which is what tells the planner to avoid a blend.
    var beatConfidence: Float
    /// Sample-accurate beat timings in seconds.
    var beatGrid: [TimeInterval]
    /// Bar starts, usually every 4th beat.
    var downbeats: [TimeInterval]
    var key: MusicalKey
    var camelotPosition: String
    /// Normalized RMS energy, 10 windows per second.
    var energyCurve: [Float]
    var introEnd: TimeInterval?
    var outroStart: TimeInterval?
    var cuePoints: [CuePoint]
    var duration: TimeInterval
    var analysisVersion: Int

    static let energyWindowsPerSecond: Double = 10

    /// A track we can actually beat-match instead of just crossfading.
    var hasSteadyBeat: Bool {
        beatConfidence >= 0.20 && bpm >= 60 && bpm <= 200 && beatGrid.count > 8
    }

    var camelot: CamelotPosition? { CamelotPosition(label: camelotPosition) }

    func energy(at time: TimeInterval) -> Float {
        guard !energyCurve.isEmpty else { return 0 }
        let index = Int((time * Self.energyWindowsPerSecond).rounded())
        guard index >= 0 else { return energyCurve[0] }
        guard index < energyCurve.count else { return energyCurve[energyCurve.count - 1] }
        return energyCurve[index]
    }

    /// Average energy over a window, used to spot vocals/dense outros.
    func energy(from start: TimeInterval, to end: TimeInterval) -> Float {
        guard !energyCurve.isEmpty, end > start else { return 0 }
        let lower = max(0, Int(start * Self.energyWindowsPerSecond))
        let upper = min(energyCurve.count, Int(end * Self.energyWindowsPerSecond))
        guard upper > lower else { return energy(at: start) }
        var sum: Float = 0
        for index in lower..<upper { sum += energyCurve[index] }
        return sum / Float(upper - lower)
    }

    /// Snap a time to the nearest bar start so cuts land musically.
    func nearestDownbeat(to time: TimeInterval, tolerance: TimeInterval = 2.5) -> TimeInterval? {
        guard !downbeats.isEmpty else { return nil }
        var best = downbeats[0]
        for candidate in downbeats where abs(candidate - time) < abs(best - time) {
            best = candidate
        }
        return abs(best - time) <= tolerance ? best : nil
    }

    /// Length of one bar in seconds, for overlap lengths expressed in bars.
    var barDuration: TimeInterval? {
        guard bpm > 40, bpm < 220 else { return nil }
        return (60.0 / bpm) * 4.0
    }
}
