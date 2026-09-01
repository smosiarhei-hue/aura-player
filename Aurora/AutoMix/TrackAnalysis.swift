import Foundation

// MARK: - AutoMix Analysis Model & Section Types (Sonivo AI DJ Architecture)

nonisolated enum MusicalMode: String, Codable, Sendable {
    case major
    case minor
}

nonisolated struct TimeRange: Codable, Sendable, Equatable {
    let start: Double
    let end: Double
    var duration: Double { max(0, end - start) }
}

nonisolated enum SectionType: String, Codable, Sendable {
    case intro
    case verse
    case preChorus
    case chorus
    case drop
    case breakdown
    case bridge
    case outro
    case instrumental
    case unknown
}

nonisolated struct MusicSection: Codable, Sendable {
    let start: Double
    let end: Double
    let type: SectionType
    let energy: Double
}

nonisolated enum TransitionStrategy: String, Codable, Sendable, CaseIterable {
    case NONE
    case SILENCE_TRIM
    case SIMPLE_CROSSFADE
    case BEAT_MATCH
    case BEAT_MATCH_EQ
    case BASS_SWAP
    case ENERGY_BLEND
    case DROP_SWITCH
    case BUILDUP_TO_DROP
    case FILTER_TRANSITION
    case LOOP_TRANSITION
    case ECHO_OUT
    case VOCAL_CUT
    case INSTRUMENTAL_OVERLAY
    case HARD_CUT
}

nonisolated struct MusicalKey: Codable, Sendable, Equatable {
    /// 0 = C, 1 = C#/Db, ... 11 = B
    var pitchClass: Int
    var mode: MusicalMode
    /// 0...1 correlation strength
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
    static let currentVersion = 2

    let trackID: String
    var duration: Double

    var bpm: Double?
    var bpmConfidence: Double

    var musicalKey: String?
    var keyConfidence: Double

    var energy: Double
    var danceability: Double?

    var introStart: Double
    var introEnd: Double

    var outroStart: Double
    var outroEnd: Double

    var firstBeat: Double?
    var lastBeat: Double?

    var beats: [Double]
    var downbeats: [Double]

    var sections: [MusicSection]
    var silenceRegions: [TimeRange]
    var vocalRegions: [TimeRange]
    var instrumentalRegions: [TimeRange]
    var drops: [Double]
    var buildUps: [TimeRange]

    var energyCurve: [Float]
    var analysisVersion: Int

    static let energyWindowsPerSecond: Double = 10

    var hasSteadyBeat: Bool {
        (bpmConfidence >= 0.35) && (bpm ?? 0) >= 60 && (bpm ?? 0) <= 200 && beats.count > 8
    }

    var barDuration: Double? {
        guard let b = bpm, b > 40, b < 220 else { return nil }
        return (60.0 / b) * 4.0
    }

    func energy(at time: TimeInterval) -> Float {
        guard !energyCurve.isEmpty else { return Float(energy) }
        let index = Int((time * Self.energyWindowsPerSecond).rounded())
        guard index >= 0 else { return energyCurve[0] }
        guard index < energyCurve.count else { return energyCurve[energyCurve.count - 1] }
        return energyCurve[index]
    }

    func nearestDownbeat(to time: TimeInterval, tolerance: TimeInterval = 2.5) -> TimeInterval? {
        guard !downbeats.isEmpty else { return nil }
        var best = downbeats[0]
        for candidate in downbeats where abs(candidate - time) < abs(best - time) {
            best = candidate
        }
        return abs(best - time) <= tolerance ? best : nil
    }
}
