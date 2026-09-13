import Testing
@testable import NeuroMixEngine

struct NeuroMixEngineTests {
    @Test
    func selectsBeatmatchForConfidentCloseTempos() {
        let engine = NeuroMixEngine()
        let source = features(id: "a", bpm: 120, bpmConfidence: 0.95, vocal: 0.1)
        let target = features(id: "b", bpm: 121, bpmConfidence: 0.95, vocal: 0.1)

        let plan = engine.makePlan(source: source, target: target)

        #expect(plan.kind == .beatmatch)
        #expect(plan.usedFallback == false)
        #expect(plan.targetRate > 0.99)
    }

    @Test
    func fallsBackWhenTempoConfidenceIsLow() {
        let engine = NeuroMixEngine()
        let source = features(id: "a", bpm: 120, bpmConfidence: 0.2, vocal: 0.2)
        let target = features(id: "b", bpm: 160, bpmConfidence: 0.2, vocal: 0.2)

        let plan = engine.makePlan(source: source, target: target)

        #expect(plan.kind == .crossfade)
        #expect(plan.usedFallback)
        #expect(plan.sourceRate == 1)
        #expect(plan.targetRate == 1)
    }

    @Test
    func emitsMusicalEventsForBeatmatchedTransition() {
        let engine = NeuroMixEngine()
        let source = features(id: "a", bpm: 120, bpmConfidence: 0.95, vocal: 0.1)
        let target = features(id: "b", bpm: 121, bpmConfidence: 0.95, vocal: 0.1)

        let plan = engine.makePlan(source: source, target: target)

        #expect(plan.events.contains { $0.kind == .volume })
        #expect(plan.events.contains { $0.kind == .bassCut })
        #expect(plan.events.contains { $0.kind == .bassRestore })
        #expect(plan.events.contains { $0.kind == .lowPassSweep })
        #expect(plan.events.contains { $0.kind == .echoOut })
        #expect(plan.events.allSatisfy { $0.endSeconds >= $0.startSeconds })
    }

    @Test
    func penalizesVocalClashAndAddsFilterProtection() {
        let engine = NeuroMixEngine()
        let source = features(id: "a", bpm: 120, bpmConfidence: 0.95, vocal: 1)
        let target = features(id: "b", bpm: 121, bpmConfidence: 0.95, vocal: 1)

        let plan = engine.makePlan(source: source, target: target)

        #expect(plan.events.contains { $0.kind == .highPassSweep })
    }

    private func features(
        id: String,
        bpm: Double,
        bpmConfidence: Double,
        vocal: Double
    ) -> NeuroTrackFeatures {
        NeuroTrackFeatures(
            trackID: id,
            durationSeconds: 180,
            bpm: bpm,
            bpmConfidence: bpmConfidence,
            energy: 0.6,
            loudnessLUFS: -14,
            key: "8A",
            keyConfidence: 0.8,
            vocalActivity: vocal,
            hasFadeOut: false,
            endsInSilence: false
        )
    }
}
