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
    static let currentVersion = 3

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

    /// Default placeholder when no audio could be decoded yet.
    /// Uses Apple Music standard outro lengths (~22-26s for typical songs).
    nonisolated static func minimal(trackID: String, duration: Double) -> TrackAnalysis {
        let dur = max(1, duration)
        let outroStartSec: Double
        if dur > 180 {
            outroStartSec = max(0, dur - 26.0)
        } else if dur > 90 {
            outroStartSec = max(0, dur - 22.0)
        } else {
            outroStartSec = max(0, dur - 14.0)
        }

        return TrackAnalysis(
            trackID: trackID,
            duration: dur,
            bpm: nil,
            bpmConfidence: 0,
            musicalKey: nil,
            keyConfidence: 0,
            energy: 0.65,
            danceability: nil,
            introStart: 0,
            introEnd: 6.0,
            outroStart: outroStartSec,
            outroEnd: dur,
            firstBeat: nil,
            lastBeat: nil,
            beats: [],
            downbeats: [],
            sections: [],
            silenceRegions: [],
            vocalRegions: [],
            instrumentalRegions: [],
            drops: [],
            buildUps: [],
            energyCurve: [],
            analysisVersion: currentVersion
        )
    }

    /// Parse the stored "C maj" / "A min" display name into a Camelot position.
    var camelotPosition: CamelotPosition? {
        guard let musicalKey else { return nil }
        let parts = musicalKey.split(separator: " ")
        guard let name = parts.first.map(String.init),
              let pitchClass = MusicalKey.pitchNames.firstIndex(of: name.uppercased()) else { return nil }
        let isMajor = parts.count > 1 ? parts[1].lowercased().hasPrefix("maj") : true
        return CamelotPosition(
            key: MusicalKey(pitchClass: pitchClass, mode: isMajor ? .major : .minor, confidence: Float(keyConfidence))
        )
    }

    /// Trailing silence region overlapping the very end of the track.
    var trailingSilence: TimeRange? {
        silenceRegions.last { $0.end >= duration - 1.0 && $0.duration >= 0.4 }
    }

    var lastVocalEnd: TimeInterval? {
        vocalRegions.last(where: { $0.end <= duration })?.end
    }

    var firstVocalStart: TimeInterval? {
        vocalRegions.first?.start
    }

    func vocalActive(at time: TimeInterval) -> Bool {
        vocalRegions.contains { time >= $0.start - 0.5 && time <= $0.end + 0.5 }
    }

    /// Average energy of a time window from the measured curve.
    func averageEnergy(from start: TimeInterval, to end: TimeInterval) -> Double {
        guard !energyCurve.isEmpty, end > start else { return energy }
        let first = max(0, Int(start * Self.energyWindowsPerSecond))
        let last = min(energyCurve.count - 1, Int(end * Self.energyWindowsPerSecond))
        guard last > first else { return Double(energyCurve[max(0, min(energyCurve.count - 1, first))]) }
        let slice = energyCurve[first...last]
        return Double(slice.reduce(0, +) / Float(slice.count))
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
