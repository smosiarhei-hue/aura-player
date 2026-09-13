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
            source: NeuroTrackFeatures(
                trackID: source.trackID.raw,
                durationSeconds: source.durationSec,
                bpm: source.bpm > 0 ? Double(source.bpm) : nil,
                bpmConfidence: Double(source.confidence.bpm),
                energy: averageEnergy(source.energyCurve),
                loudnessLUFS: Double(source.integratedLUFS),
                key: source.camelotKey,
                keyConfidence: Double(source.confidence.key),
                vocalActivity: averageEnergy(source.vocalPresence),
                hasFadeOut: source.hasFadeOut,
                endsInSilence: source.endsInSilence
            ),
            target: NeuroTrackFeatures(
                trackID: target.trackID.raw,
                durationSeconds: target.durationSec,
                bpm: target.bpm > 0 ? Double(target.bpm) : nil,
                bpmConfidence: Double(target.confidence.bpm),
                energy: averageEnergy(target.energyCurve),
                loudnessLUFS: Double(target.integratedLUFS),
                key: target.camelotKey,
                keyConfidence: Double(target.confidence.key),
                vocalActivity: averageEnergy(target.vocalPresence),
                hasFadeOut: target.hasFadeOut,
                endsInSilence: target.endsInSilence
            ),
            settings: settings
        )
    }

    private func averageEnergy(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        let sum = values.reduce(0) { $0 + Double($1) }
        return min(1, max(0, sum / Double(values.count)))
    }
}
