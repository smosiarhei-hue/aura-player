// Path: Packages/AutoMixV2/Sources/MixModels/AnalysisModels.swift

import Foundation

public enum SegmentType: String, Sendable, Codable, Equatable {
    case silence
    case intro
    case verse
    case chorus
    case bridge
    case drop
    case breakdown
    case outro
    case unknown
}

public struct Segment: Sendable, Codable, Equatable {
    public let startSec: Double
    public let endSec: Double
    public let type: SegmentType

    public init(startSec: Double, endSec: Double, type: SegmentType) {
        self.startSec = startSec
        self.endSec = endSec
        self.type = type
    }
}

public struct Confidence: Sendable, Codable, Equatable {
    public let bpm: Float
    public let downbeats: Float
    public let key: Float

    public init(bpm: Float, downbeats: Float, key: Float) {
        self.bpm = bpm
        self.downbeats = downbeats
        self.key = key
    }
}

public struct TrackProfile: Sendable, Codable, Equatable {
    public static let currentVersion = 1

    public let profileVersion: Int
    public let trackID: TrackID
    public let durationSec: Double
    public let sourceSampleRate: Double
    public let sourceBitrateKbps: Int?
    public let bpm: Float
    public let beatsSec: [Double]
    public let downbeatsSec: [Double]
    public let phraseStartsSec: [Double]
    public let tempoStability: Float
    public let camelotKey: String?
    public let integratedLUFS: Float
    public let loudnessCurveLUFS: [Float]
    public let energyCurve: [Float]
    public let hasFadeOut: Bool
    public let endsInSilence: Bool
    public let vocalPresence: [Float]
    public let segments: [Segment]
    public let mixInSec: Double
    public let mixOutSec: Double
    public let mixable: Bool
    public let confidence: Confidence

    public init(
        profileVersion: Int = Self.currentVersion,
        trackID: TrackID,
        durationSec: Double,
        sourceSampleRate: Double,
        sourceBitrateKbps: Int?,
        bpm: Float,
        beatsSec: [Double],
        downbeatsSec: [Double],
        phraseStartsSec: [Double],
        tempoStability: Float,
        camelotKey: String?,
        integratedLUFS: Float,
        loudnessCurveLUFS: [Float],
        energyCurve: [Float],
        hasFadeOut: Bool,
        endsInSilence: Bool,
        vocalPresence: [Float],
        segments: [Segment],
        mixInSec: Double,
        mixOutSec: Double,
        mixable: Bool,
        confidence: Confidence
    ) {
        self.profileVersion = profileVersion
        self.trackID = trackID
        self.durationSec = durationSec
        self.sourceSampleRate = sourceSampleRate
        self.sourceBitrateKbps = sourceBitrateKbps
        self.bpm = bpm
        self.beatsSec = beatsSec
        self.downbeatsSec = downbeatsSec
        self.phraseStartsSec = phraseStartsSec
        self.tempoStability = tempoStability
        self.camelotKey = camelotKey
        self.integratedLUFS = integratedLUFS
        self.loudnessCurveLUFS = loudnessCurveLUFS
        self.energyCurve = energyCurve
        self.hasFadeOut = hasFadeOut
        self.endsInSilence = endsInSilence
        self.vocalPresence = vocalPresence
        self.segments = segments
        self.mixInSec = mixInSec
        self.mixOutSec = mixOutSec
        self.mixable = mixable
        self.confidence = confidence
    }
}
