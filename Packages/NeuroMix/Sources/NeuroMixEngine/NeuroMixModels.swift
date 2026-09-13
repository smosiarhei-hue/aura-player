import Foundation

public struct NeuroTrackFeatures: Sendable, Equatable {
    public let trackID: String
    public let durationSeconds: Double
    public let bpm: Double?
    public let bpmConfidence: Double
    public let energy: Double
    public let loudnessLUFS: Double?
    public let key: String?
    public let keyConfidence: Double
    public let vocalActivity: Double
    public let hasFadeOut: Bool
    public let endsInSilence: Bool

    public init(
        trackID: String,
        durationSeconds: Double,
        bpm: Double?,
        bpmConfidence: Double,
        energy: Double,
        loudnessLUFS: Double?,
        key: String?,
        keyConfidence: Double,
        vocalActivity: Double,
        hasFadeOut: Bool,
        endsInSilence: Bool
    ) {
        self.trackID = trackID
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.bpmConfidence = Self.clamp(bpmConfidence)
        self.energy = Self.clamp(energy)
        self.loudnessLUFS = loudnessLUFS
        self.key = key
        self.keyConfidence = Self.clamp(keyConfidence)
        self.vocalActivity = Self.clamp(vocalActivity)
        self.hasFadeOut = hasFadeOut
        self.endsInSilence = endsInSilence
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

public enum NeuroTransitionKind: String, Sendable, Codable, Equatable {
    case beatmatch
    case crossfade
    case filterOut
    case hardCut
    case none
}

public struct NeuroTransitionPlan: Sendable, Codable, Equatable {
    public let sourceTrackID: String
    public let targetTrackID: String
    public let kind: NeuroTransitionKind
    public let durationSeconds: Double
    public let sourceStartSeconds: Double
    public let targetStartSeconds: Double
    public let sourceRate: Double
    public let targetRate: Double
    public let sourceGain: Double
    public let targetGain: Double
    public let score: Double
    public let reason: String
    public let usedFallback: Bool

    public init(
        sourceTrackID: String,
        targetTrackID: String,
        kind: NeuroTransitionKind,
        durationSeconds: Double,
        sourceStartSeconds: Double,
        targetStartSeconds: Double,
        sourceRate: Double,
        targetRate: Double,
        sourceGain: Double,
        targetGain: Double,
        score: Double,
        reason: String,
        usedFallback: Bool
    ) {
        self.sourceTrackID = sourceTrackID
        self.targetTrackID = targetTrackID
        self.kind = kind
        self.durationSeconds = max(0, durationSeconds.isFinite ? durationSeconds : 0)
        self.sourceStartSeconds = max(0, sourceStartSeconds.isFinite ? sourceStartSeconds : 0)
        self.targetStartSeconds = max(0, targetStartSeconds.isFinite ? targetStartSeconds : 0)
        self.sourceRate = Self.safeRate(sourceRate)
        self.targetRate = Self.safeRate(targetRate)
        self.sourceGain = Self.safeGain(sourceGain)
        self.targetGain = Self.safeGain(targetGain)
        self.score = min(1, max(0, score.isFinite ? score : 0))
        self.reason = reason
        self.usedFallback = usedFallback
    }

    private static func safeRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1.08, max(0.92, value))
    }

    private static func safeGain(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }
}

public struct NeuroMixSettings: Sendable, Equatable {
    public var crossfadeSeconds: Double
    public var maxTempoCorrection: Double
    public var minimumConfidence: Double

    public init(
        crossfadeSeconds: Double = 6,
        maxTempoCorrection: Double = 0.06,
        minimumConfidence: Double = 0.55
    ) {
        self.crossfadeSeconds = max(0, crossfadeSeconds.isFinite ? crossfadeSeconds : 6)
        self.maxTempoCorrection = min(0.08, max(0, maxTempoCorrection.isFinite ? maxTempoCorrection : 0.06))
        self.minimumConfidence = min(1, max(0, minimumConfidence.isFinite ? minimumConfidence : 0.55))
    }
}
