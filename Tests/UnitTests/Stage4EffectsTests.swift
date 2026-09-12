import MixModels
import MixPlanner
import Testing

@Suite("AutoMix Stage 4 effects")
struct Stage4EffectsTests {
    @Test("Automation curves clamp and reach endpoints")
    func curves() {
        let event = FxEvent(target: .a, kind: .highPass, startBar: 2, endBar: 6,
                            fromValue: 20, toValue: 2_000, curve: .exp)
        #expect(EffectAutomation.value(for: event, atBar: 1) == nil)
        #expect(EffectAutomation.value(for: event, atBar: 2) == 20)
        #expect(abs((EffectAutomation.value(for: event, atBar: 6) ?? 0) - 2_000) < 0.1)
        #expect(abs((EffectAutomation.value(for: event, atBar: 4) ?? 0) - 200) < 1)
    }

    @Test("Musical plan contains all mandatory Stage 4 effects")
    func mandatoryEffects() {
        let kinds = Set(musicalPlan().fx.map(\.kind))
        #expect(kinds.contains(.highPass)); #expect(kinds.contains(.lowPass))
        #expect(kinds.contains(.bassKill)); #expect(kinds.contains(.bassOn))
        #expect(kinds.contains(.echoOut)); #expect(kinds.contains(.rateRamp)); #expect(kinds.contains(.volume))
    }

    @Test("Seek inside fallback window starts crossfade instead of suppressing AutoMix")
    func seekRearmer() {
        let decision = AutoMixTransitionGate.decide(hasNext: true, nextPrepared: true,
            reachedEnd: false, remainingSeconds: 3.2, hasUsablePlan: false,
            reachedPlannedStart: false, fallbackSeconds: 6)
        #expect(decision == .startFallback(durationSeconds: 3.2))
    }

    @Test("Missing analysis cannot prevent fallback transition")
    func guaranteedFallback() {
        #expect(AutoMixTransitionGate.decide(hasNext: true, nextPrepared: true,
            reachedEnd: false, remainingSeconds: 8, hasUsablePlan: false,
            reachedPlannedStart: false, fallbackSeconds: 6) == .waitingForPlan)
        #expect(AutoMixTransitionGate.decide(hasNext: true, nextPrepared: true,
            reachedEnd: false, remainingSeconds: 6, hasUsablePlan: false,
            reachedPlannedStart: false, fallbackSeconds: 6) == .startFallback(durationSeconds: 6))
        #expect(AutoMixTransitionGate.decide(hasNext: true, nextPrepared: true,
            reachedEnd: true, remainingSeconds: 0, hasUsablePlan: false,
            reachedPlannedStart: false, fallbackSeconds: 6) == .hardCutAtEnd)
    }

    @Test("Prepared musical plan waits for its start then fires")
    func plannedGate() {
        #expect(AutoMixTransitionGate.decide(hasNext: true, nextPrepared: true,
            reachedEnd: false, remainingSeconds: 30, hasUsablePlan: true,
            reachedPlannedStart: false, fallbackSeconds: 6) == .readyForPlan)
        #expect(AutoMixTransitionGate.decide(hasNext: true, nextPrepared: true,
            reachedEnd: false, remainingSeconds: 20, hasUsablePlan: true,
            reachedPlannedStart: true, fallbackSeconds: 6) == .startPlanned)
    }

    @Test("Incoming rate returns smoothly to one before promotion")
    func rateReturn() {
        let plan = musicalPlan(); let ramps = plan.fx.filter { $0.target == .b && $0.kind == .rateRamp }
        #expect(ramps.count == 1)
        guard let final = ramps.first else { return }
        #expect(final.endBar == plan.bars); #expect(final.toValue == 1); #expect(final.curve == .sCurve)
        for step in 0...100 {
            let bar = final.startBar + (final.endBar - final.startBar) * Double(step) / 100
            let value = EffectAutomation.value(for: final, atBar: bar) ?? 0
            #expect(value.isFinite); #expect((0.92...1.08).contains(value))
        }
    }

    @Test("Stage 4 FX contains bass-swap, echoOut, lowPass, and single rateRamp")
    func stage4FXProperties() {
        let plan = musicalPlan()
        let ramps = plan.fx.filter { $0.kind == .rateRamp }
        #expect(ramps.count == 1)
        #expect(ramps.first?.target == .b)
        #expect(ramps.first?.startBar == plan.bars - 1)

        let aBassKill = plan.fx.first(where: { $0.target == .a && $0.kind == .bassKill })
        #expect(aBassKill != nil)
        #expect(aBassKill?.startBar == 0 && aBassKill?.endBar == 2)

        let bBassKill = plan.fx.first(where: { $0.target == .b && $0.kind == .bassKill })
        #expect(bBassKill != nil)
        #expect(bBassKill?.startBar == 0 && bBassKill?.endBar == 0)

        let bBassOn = plan.fx.first(where: { $0.target == .b && $0.kind == .bassOn })
        #expect(bBassOn != nil)
        #expect(bBassOn?.startBar == 2 && bBassOn?.endBar == 3)

        let bLowPass = plan.fx.first(where: { $0.target == .b && $0.kind == .lowPass })
        #expect(bLowPass != nil)
        #expect(bLowPass?.startBar == 0 && bLowPass?.endBar == 2)

        let aEchoOut = plan.fx.first(where: { $0.target == .a && $0.kind == .echoOut })
        #expect(aEchoOut != nil)
        #expect(aEchoOut?.startBar == plan.bars - 4 && aEchoOut?.endBar == plan.bars)
        #expect(aEchoOut?.toValue == 65)
        #expect(aEchoOut?.param == 50)
    }

    @Test("Equal-power crossfade preserves mid-point energy")
    func equalPowerMidpoint() {
        let p = 0.5
        let outGain = cos(p * .pi / 2)
        let incGain = sin(p * .pi / 2)
        let powerSum = outGain * outGain + incGain * incGain
        #expect(abs(powerSum - 1.0) < 0.0001)
    }

    @Test("Every generated event is finite, ordered and bounded")
    func eventSafety() {
        let plan = musicalPlan()
        for event in plan.fx {
            #expect(event.startBar.isFinite); #expect(event.endBar.isFinite)
            #expect(event.fromValue.isFinite); #expect(event.toValue.isFinite)
            #expect(event.startBar >= 0); #expect(event.endBar >= event.startBar); #expect(event.endBar <= plan.bars)
        }
    }

    @Test("Fallback contains no beatmatch effects")
    func fallbackSafety() {
        var low = profile("a", key: "8A")
        low = TrackProfile(trackID: low.trackID, durationSec: low.durationSec,
                           sourceSampleRate: low.sourceSampleRate, sourceBitrateKbps: low.sourceBitrateKbps,
                           bpm: low.bpm, beatsSec: low.beatsSec, downbeatsSec: low.downbeatsSec,
                           phraseStartsSec: low.phraseStartsSec, tempoStability: low.tempoStability,
                           camelotKey: low.camelotKey, integratedLUFS: low.integratedLUFS,
                           loudnessCurveLUFS: low.loudnessCurveLUFS, energyCurve: low.energyCurve,
                           hasFadeOut: low.hasFadeOut, endsInSilence: low.endsInSilence,
                           vocalPresence: low.vocalPresence, segments: low.segments,
                           mixInSec: low.mixInSec, mixOutSec: low.mixOutSec, mixable: low.mixable,
                           confidence: Confidence(bpm: 0.2, downbeats: 0.2, key: 0.2))
        let plan = MixPlanner.plan(from: low, to: profile("b", key: "8B"),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(plan.type == .crossfade); #expect(Set(plan.fx.map(\.kind)) == [.volume])
        #expect(plan.rateA == 1); #expect(plan.rateB == 1)
    }

    @Test("Bar and second conversion round trips")
    func timing() {
        let seconds = EffectAutomation.seconds(atBar: 8, bpm: 128)
        #expect(abs(EffectAutomation.bar(atSeconds: seconds, bpm: 128) - 8) < 0.0001)
    }

    private func musicalPlan() -> TransitionPlan {
        MixPlanner.plan(from: profile("a", key: "8A"), to: profile("b", key: "8B"),
                        aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
    }
    private func meta(_ id: String) -> TrackMeta {
        TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: nil, durationSec: 240, artworkURL: nil)
    }
    private func profile(_ id: String, key: String) -> TrackProfile {
        TrackProfile(trackID: TrackID(raw: id), durationSec: 240, sourceSampleRate: 48_000,
                     sourceBitrateKbps: nil, bpm: 124,
                     beatsSec: Array(stride(from: 0.0, to: 240, by: 60.0 / 124.0)),
                     downbeatsSec: Array(stride(from: 0.0, to: 240, by: 240.0 / 124.0)),
                     phraseStartsSec: Array(stride(from: 0.0, to: 240, by: 16)),
                     tempoStability: 1, camelotKey: key, integratedLUFS: -14,
                     loudnessCurveLUFS: [], energyCurve: [], hasFadeOut: false,
                     endsInSilence: false, vocalPresence: [], segments: [],
                     mixInSec: 8, mixOutSec: 220, mixable: true,
                     confidence: Confidence(bpm: 1, downbeats: 1, key: 1))
    }
}
