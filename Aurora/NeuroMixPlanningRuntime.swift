import MixModels
import NeuroMixEngine

@MainActor
final class NeuroMixPlanningRuntime {
    static let shared = NeuroMixPlanningRuntime()

    private let engine = NeuroMixEngine()

    private init() {}

    func plan(
        from source: TrackProfile,
        to target: TrackProfile,
        settings: NeuroMixSettings = NeuroMixSettings()
    ) -> NeuroTransitionPlan {
        engine.makePlan(
            source: features(from: source),
            target: features(from: target),
            settings: settings
        )
    }

    private func features(from profile: TrackProfile) -> NeuroTrackFeatures {
        let beatGrid = NeuroBeatGrid(
            bpm: Double(profile.bpm),
            offsetSeconds: profile.beatsSec.first ?? 0,
            confidence: Double(profile.confidence.bpm)
        )
        let phrases = profile.phraseStartsSec.map { start in
            NeuroPhraseMarker(
                startSeconds: start,
                energy: nearestEnergy(at: start, in: profile.energyCurve),
                isDrop: profile.segments.contains {
                    $0.type == .drop && start >= $0.startSec && start <= $0.endSec
                }
            )
        }
        let segments = profile.segments.map {
            NeuroSegment(
                startSeconds: $0.startSec,
                endSeconds: $0.endSec,
                kind: NeuroSegmentKind(rawValue: $0.type.rawValue) ?? .unknown
            )
        }
        return NeuroTrackFeatures(
            trackID: profile.trackID.raw,
            durationSeconds: profile.durationSec,
            bpm: profile.bpm > 0 ? Double(profile.bpm) : nil,
            bpmConfidence: Double(profile.confidence.bpm),
            energy: averageEnergy(profile.energyCurve),
            loudnessLUFS: Double(profile.integratedLUFS),
            key: profile.camelotKey,
            keyConfidence: Double(profile.confidence.key),
            vocalActivity: averageEnergy(profile.vocalPresence),
            hasFadeOut: profile.hasFadeOut,
            endsInSilence: profile.endsInSilence,
            beatGrid: profile.bpm > 0 ? beatGrid : nil,
            phraseMarkers: phrases,
            segments: segments,
            vocalActivityCurve: profile.vocalPresence.map(Double.init)
        )
    }

    private func averageEnergy(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        let sum = values.reduce(0) { $0 + Double($1) }
        return min(1, max(0, sum / Double(values.count)))
    }

    private func nearestEnergy(at seconds: Double, in curve: [Float]) -> Double {
        guard !curve.isEmpty else { return 0.5 }
        let index = min(curve.count - 1, max(0, Int(seconds)))
        return min(1, max(0, Double(curve[index])))
    }
}
