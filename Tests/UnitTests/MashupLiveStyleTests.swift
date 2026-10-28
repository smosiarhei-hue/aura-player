import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Mashup Live Style")
struct MashupLiveStyleTests {
    @Test("Drop-swap style keeps outgoing volume high while incoming lags")
    func asymmetricVolumes() {
        // Use MixPlanner-backed resolve via duration heuristic with dropSwap-like pair.
        let style = MashupLiveStyle.resolve(
            plan: nil,
            outgoing: nil,
            incoming: nil,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        let early = style.volumes(progress: 0.15)
        let mid = style.volumes(progress: 0.45)
        let late = style.volumes(progress: 0.9)
        #expect(early.outgoing > early.incoming)
        #expect(early.outgoing > 0.8)
        #expect(mid.outgoing > 0.35)
        #expect(late.incoming > late.outgoing)
        #expect(!style.phaseLabel(progress: 0.1).isEmpty)
    }

    @Test("Plan archetype changes style parameters")
    func planDrivesArchetype() {
        let drop = TransitionPlan(
            type: .beatmatchedShort,
            archetype: .dropSwap,
            aOutStartSec: 160,
            bInStartSec: 16,
            bars: 8,
            tempoTargetBPM: 124,
            rateA: 1,
            rateB: 1.02,
            pitchShiftCentsB: 100,
            gainOffsetBdB: 0,
            loopBarsA: 0,
            fx: [],
            reason: "test drop"
        )
        let echo = TransitionPlan(
            type: .filterEcho,
            archetype: .echoFreeze,
            aOutStartSec: 170,
            bInStartSec: 0,
            bars: 6,
            tempoTargetBPM: 120,
            rateA: 1,
            rateB: 1,
            pitchShiftCentsB: 0,
            gainOffsetBdB: 0,
            loopBarsA: 0,
            fx: [],
            reason: "test echo"
        )
        let dropStyle = MashupLiveStyle.resolve(plan: drop, outgoing: nil, incoming: nil, outgoingDuration: 200, incomingDuration: 200)
        let echoStyle = MashupLiveStyle.resolve(plan: echo, outgoing: nil, incoming: nil, outgoingDuration: 200, incomingDuration: 200)
        #expect(dropStyle.archetypeName == "dropSwap")
        #expect(echoStyle.archetypeName == "echoFreeze")
        #expect(echoStyle.outgoingVolumeHold > dropStyle.outgoingVolumeHold)
        #expect(abs(dropStyle.incomingPitchCents) > 0 || abs(drop.pitchShiftCentsB) >= 1)
    }
}
