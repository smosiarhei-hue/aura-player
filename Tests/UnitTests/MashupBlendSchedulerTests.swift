import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Mashup Blend Scheduler")
struct MashupBlendSchedulerTests {
    @Test("Heuristic cue is not a fixed N-seconds-from-end window")
    func heuristicUsesOutroNotSliderAlone() {
        let duration = 200.0
        let preferred = 6.0
        let plan = MashupBlendScheduler.schedule(
            outgoingDuration: duration,
            incomingDuration: 210,
            preferredBlendSec: preferred
        )
        // Must start in the final quarter, not at duration - preferred.
        #expect(plan.outgoingCueSec >= duration * 0.75 - 0.01)
        #expect(plan.outgoingCueSec < duration - preferred)
        #expect(plan.blendDurationSec >= MashupBlendScheduler.minimumBlendSec)
        #expect(plan.blendDurationSec <= MashupBlendScheduler.maximumBlendSec)
        #expect(plan.incomingStartSec >= 0)
    }

    @Test("Profile mixOut / mixIn drive the live schedule")
    func profilesDriveCues() {
        let a = profile("a", duration: 210, mixIn: 8, mixOut: 168, bpm: 124)
        let b = profile("b", duration: 200, mixIn: 16, mixOut: 160, bpm: 126)
        let plan = MashupBlendScheduler.schedule(
            outgoingDuration: 210,
            incomingDuration: 200,
            preferredBlendSec: 8,
            outgoing: a,
            incoming: b
        )
        #expect(plan.outgoingCueSec >= 210 * 0.75 - 0.5)
        #expect(plan.incomingStartSec >= 8)
        #expect(plan.blendDurationSec >= 4)
        #expect(plan.reason.contains("Profile") || plan.reason.contains("mixOut"))
    }

    @Test("Short tracks fall back safely")
    func shortTrackFallback() {
        let plan = MashupBlendScheduler.schedule(
            outgoingDuration: 18,
            incomingDuration: 18,
            preferredBlendSec: 8
        )
        #expect(plan.outgoingCueSec >= 0)
        #expect(plan.blendDurationSec >= MashupBlendScheduler.minimumBlendSec)
        #expect(plan.outgoingCueSec + plan.blendDurationSec <= 18 + 0.01 || plan.outgoingCueSec <= 18)
    }

    @Test("heuristicCues mixOut never before 75%")
    func mixOutFloor() {
        let cue = MashupBlendScheduler.heuristicCues(duration: 240, bpm: 120, role: .mixOut)
        #expect(cue >= 240 * 0.75 - 0.01)
        #expect(cue <= 240 - MashupBlendScheduler.minimumTailSec + 0.01)
    }

    private func profile(
        _ id: String,
        duration: Double,
        mixIn: Double,
        mixOut: Double,
        bpm: Float
    ) -> TrackProfile {
        TrackProfile(
            trackID: TrackID(raw: id),
            durationSec: duration,
            sourceSampleRate: 44_100,
            sourceBitrateKbps: 320,
            bpm: bpm,
            beatsSec: Array(stride(from: 0.0, to: duration, by: 0.5)),
            downbeatsSec: Array(stride(from: 0.0, to: duration, by: 2)),
            phraseStartsSec: Array(stride(from: 0.0, to: duration, by: 16)),
            tempoStability: 0.92,
            camelotKey: "8A",
            integratedLUFS: -14,
            loudnessCurveLUFS: [],
            energyCurve: Array(repeating: 0.6, count: Int(duration)),
            hasFadeOut: false,
            endsInSilence: false,
            vocalPresence: [],
            segments: [Segment(startSec: 64, endSec: 96, type: .drop)],
            mixInSec: mixIn,
            mixOutSec: mixOut,
            mixable: true,
            confidence: Confidence(bpm: 0.9, downbeats: 0.9, key: 0.9)
        )
    }
}
