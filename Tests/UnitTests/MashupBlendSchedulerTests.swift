import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Mashup Blend Scheduler")
struct MashupBlendSchedulerTests {
    @Test("Heuristic cue is not a fixed N-seconds-from-end window")
    func heuristicUsesOutroNotSliderAlone() {
        let duration = 200.0
        let plan = MashupBlendScheduler.schedule(
            outgoingDuration: duration,
            incomingDuration: 210,
            preferredBlendSec: MashupBlendScheduler.defaultPreferredBlendSec
        )
        // Must start in the final quarter; blend follows remaining outro tail.
        #expect(plan.outgoingCueSec >= duration * 0.75 - 0.01)
        #expect(plan.outgoingCueSec < duration - MashupBlendScheduler.minimumBlendSec)
        #expect(abs(plan.blendDurationSec - (duration - plan.outgoingCueSec)) < 0.05
                || plan.blendDurationSec <= MashupBlendScheduler.maximumBlendSec)
        #expect(plan.blendDurationSec >= MashupBlendScheduler.minimumBlendSec)
        #expect(plan.blendDurationSec <= MashupBlendScheduler.maximumBlendSec)
        #expect(plan.incomingStartSec >= 0)
    }

    @Test("Preferred slider value does not cap natural outro blend")
    func preferredDoesNotCapNaturalBlend() {
        let duration = 200.0
        let shortPreferred = 6.0
        let plan = MashupBlendScheduler.schedule(
            outgoingDuration: duration,
            incomingDuration: 210,
            preferredBlendSec: shortPreferred
        )
        // Natural outro for a 200s track is well above a 6s slider preference.
        #expect(plan.blendDurationSec > shortPreferred + 1)
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

    @Test("Shortened Automix blend re-anchors cue A to the tail")
    func reanchorOutgoingCueToTail() {
        let total = 210.52
        let planCue = total - 26.13 // long 13-bar plan
        let blend = 16.0
        let cue = MashupBlendScheduler.reanchorOutgoingCue(
            preferredCue: planCue,
            totalDur: total,
            blend: blend
        )
        #expect(abs(cue - (total - blend)) < 0.05)
        #expect(cue >= total * 0.75 - 0.01)
        // Old bug: keep planCue + blend=8 → LAND ~18s before song end.
        let oldLandAbandoned = total - (planCue + 8)
        #expect(oldLandAbandoned > 10)
        #expect(abs(total - (cue + blend)) < 0.05)
    }

    @Test("Valid eight-bar plan keeps its earlier cue")
    func keepsPlannedMusicalWindow() {
        let blend = 8 * 240.0 / 129.2
        #expect(MashupBlendScheduler.plannedCueIfUsable(
            cue: 150, duration: 182.5, blend: blend, outgoingRate: 1
        ) == 150)
        #expect(MashupBlendScheduler.plannedLandProgress(bars: 8) == 0.875)
        #expect(MashupBlendScheduler.plannedCueIfUsable(
            cue: 170, duration: 182.5, blend: blend, outgoingRate: 1
        ) == nil)
        #expect(MashupBlendScheduler.plannedCueIfUsable(
            cue: 130, duration: 182.5, blend: blend, outgoingRate: 1
        ) == nil)
    }

    @Test("Tail-aligned blend can recover an earlier detected downbeat")
    func tailAlignedGridRecovery() {
        func snap(outgoing: [Double], incoming: [Double] = [8.8],
                  notBefore: Double = 147.45, cue: Double = 191.9) -> (outgoing: Double, incoming: Double)? {
            MashupBlendScheduler.retargetToDownbeats(
                outgoingCue: cue, incomingCue: 8.8,
                outgoingDuration: 198.3, incomingDuration: 125.3,
                blend: 6.4, outgoingRate: 1, notBefore: notBefore,
                outgoingBPM: 117.45, incomingBPM: 109.96,
                outgoingDownbeats: outgoing, incomingDownbeats: incoming
            )
        }
        #expect(snap(outgoing: [190.3])?.outgoing == 190.3)
        #expect(snap(outgoing: [189.7]) == nil)
        #expect(snap(outgoing: [190.3], notBefore: 190.4) == nil)
        #expect(snap(outgoing: [190.3], incoming: [9.0]) == nil)
        #expect(snap(outgoing: [190.3], cue: 189.3) == nil)
        let accelerated = MashupBlendScheduler.retargetToDownbeats(
            outgoingCue: 191.9, incomingCue: 8.8,
            outgoingDuration: 198.3, incomingDuration: 125.3,
            blend: 6.4, outgoingRate: 1.08, notBefore: 147.45,
            outgoingBPM: 117.45, incomingBPM: 109.96,
            outgoingDownbeats: [190.3, 191.5], incomingDownbeats: [8.8]
        )
        #expect(accelerated?.outgoing == 190.3)
        #expect((accelerated?.outgoing ?? 198.3) + 6.4 * 1.08 <= 198.3)
    }

    @Test("Automix incoming cue stays in the intro")
    func clampIncomingCueToIntro() {
        let midBody = MashupBlendScheduler.clampAutomixIncomingCue(
            preferred: 38,
            incomingDur: 228
        )
        #expect(midBody <= 18)
        let intro = MashupBlendScheduler.clampAutomixIncomingCue(
            preferred: 13.2,
            incomingDur: 228
        )
        #expect(abs(intro - 13.2) < 0.01)
        // Field 1151: cold open 0.1 must lift off the floor.
        let cold = MashupBlendScheduler.clampAutomixIncomingCue(
            preferred: 0.1,
            incomingDur: 212
        )
        #expect(cold >= MashupBlendScheduler.minimumIncomingCueSec)
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
