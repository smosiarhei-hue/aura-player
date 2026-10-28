// Path: Sonivo/MixPlanRealtimeTransitionRunner.swift
//
// Runs a MixPlanner mashup TransitionPlan on DualDeckAudioEngine.
// Used when AutoMix V2 / Neuro ownership is active; PlayerCore mirrors a
// vocal↔instrumental mashup via MashupLiveEQEnvelope for the live path.

import AudioEngineCore
import Foundation
import MixModels
import MixPlanner

@MainActor
final class DualDeckMashupAudioAdapter: MashupTransitionAudio {
    private let engine: DualDeckAudioEngine

    init(engine: DualDeckAudioEngine) {
        self.engine = engine
    }

    func applyEffect(_ kind: FxKind, value: Float, param: Float?, bpm: Float, to deck: Deck) async {
        await engine.applyEffect(kind, value: value, param: param, bpm: bpm, to: deck)
    }

    func setRate(_ rate: Float, for deck: Deck) async {
        await engine.setRate(rate, for: deck)
    }

    func setPitchCents(_ cents: Float, for deck: Deck) async {
        await engine.setPitchCents(cents, for: deck)
    }

    func resetEffects(_ deck: Deck, preservingRate: Bool) async {
        await engine.resetEffects(deck, preservingRate: preservingRate)
    }
}

/// Live PlayerCore mashup EQ offsets (6 bands: 60, 150, 400, 1000, 2400, 15000).
/// Volumes stay on CrossfadeCurve; this shapes a DJ-style vocal↔instrumental handoff:
/// bass swap, HPF riser, vocal hold/pocket, mid duck, and soft LPF reveal.
/// Gains stay within `EQGainLimits` (±15 dB).
enum MashupLiveEQEnvelope {
    static let bandCount = 6

    /// Linear 0…1 ramp of `progress` across `[start, end]`.
    private static func ramp(_ progress: Double, from start: Double, to end: Double) -> Float {
        guard end > start else { return progress >= end ? 1 : 0 }
        return Float(min(1, max(0, (progress - start) / (end - start))))
    }

    static func offsets(progress: Double) -> (outgoing: [Float], incoming: [Float]) {
        let p = min(1, max(0, progress))

        // --- Outgoing: kill bass early, hold vocals, then HPF riser + mid/vocal duck ---
        let outBass = -15 * ramp(p, from: 0.00, to: 0.28)
        // HPF riser proxy: progressive body → mid cut (leaves air longer).
        let outHPFBody = -12 * ramp(p, from: 0.08, to: 0.50)
        let outHPFMid = -11 * ramp(p, from: 0.22, to: 0.72)
        // Vocal hold early (presence stays while instrumental of B builds), then duck.
        let outVocalHold = 2.5 * (1 - ramp(p, from: 0.32, to: 0.52))
        let outVocalDuck = -13 * ramp(p, from: 0.42, to: 0.88)
        let outVocal = outVocalHold + outVocalDuck
        // Mid duck clears a pocket for incoming vocal soft-reveal.
        let outMidDuck = -9 * ramp(p, from: 0.55, to: 0.95)
        let outAir = -7 * ramp(p, from: 0.62, to: 1.00)

        // --- Incoming: instrumental builds under vocal pocket, then bass + soft reveal ---
        let inBass = -15 * (1 - ramp(p, from: 0.30, to: 0.72))
        // Soft LPF reveal: start darker, open presence/air through the second half.
        let inAirCut = -11 * (1 - ramp(p, from: 0.38, to: 0.92))
        let inPresenceOpen = -9 * (1 - ramp(p, from: 0.34, to: 0.82))
        // Vocal pocket: keep B vocals ducked while A vocals hold / instrumental layers.
        let inVocalPocket = -14 * (1 - ramp(p, from: 0.48, to: 0.90))
        // Slight body lift while pocketed so the instrumental bed is audible.
        let inBodyLift = 3.0 * ramp(p, from: 0.04, to: 0.22) * (1 - ramp(p, from: 0.45, to: 0.70))
        // Mid duck mid-window, then release for soft reveal.
        let inMidDuck = -7 * ramp(p, from: 0.22, to: 0.42) * (1 - ramp(p, from: 0.58, to: 0.86))

        return (
            [
                outBass,
                outBass * 0.88,
                outHPFBody + outMidDuck * 0.55,
                outVocal + outHPFMid * 0.45 + outMidDuck * 0.35,
                outVocal * 0.92 + outHPFMid * 0.30,
                outAir
            ],
            [
                inBass,
                inBass * 0.88,
                inBodyLift + inMidDuck,
                inVocalPocket * 0.88 + inMidDuck * 0.45,
                inVocalPocket + inPresenceOpen * 0.55,
                inAirCut
            ]
        )
    }

    /// True when either deck still has audible mashup shaping.
    static func isAudible(progress: Double) -> Bool {
        let shaped = offsets(progress: progress)
        return shaped.outgoing.contains { abs($0) > 0.01 } || shaped.incoming.contains { abs($0) > 0.01 }
    }
}

@MainActor
final class MixPlanRealtimeTransitionRunner {
    private let engine: DualDeckAudioEngine

    init(engine: DualDeckAudioEngine) {
        self.engine = engine
    }

    /// Prefetch, play both decks, execute mashup FX timeline, then stop outgoing.
    func execute(
        _ plan: TransitionPlan,
        incomingURL: URL,
        outgoing: Deck = .a,
        incoming: Deck = .b
    ) async throws {
        do {
            try await engine.prepare(
                incoming,
                fileURL: incomingURL,
                startTimeSeconds: max(0, plan.bInStartSec)
            )
            await engine.resetEffects(outgoing)
            await engine.resetEffects(incoming)
            await engine.setRate(plan.rateA, for: outgoing)
            await engine.setRate(plan.rateB, for: incoming)
            await engine.setPitchCents(plan.pitchShiftCentsB, for: incoming)
            await engine.setGain(0, for: incoming)
            try await engine.play(outgoing)
            try await engine.play(incoming)

            // Seek outgoing toward the planned mix-out cue when possible.
            if plan.aOutStartSec > 0.5 {
                try? await engine.seek(outgoing, to: plan.aOutStartSec)
            }

            let adapter = DualDeckMashupAudioAdapter(engine: engine)
            try await MashupTransitionExecutor(audio: adapter).execute(plan)

            try await ContinuousClock().sleep(for: .milliseconds(700))
            await engine.stop(outgoing)
            await engine.setRate(1, for: incoming)
            await engine.setPitchCents(0, for: incoming)
            await engine.resetEffects(incoming)
            await engine.setGain(1, for: incoming)
        } catch {
            await engine.stop(incoming)
            await engine.setGain(1, for: outgoing)
            await engine.setRate(1, for: outgoing)
            await engine.setPitchCents(0, for: outgoing)
            await engine.resetEffects(outgoing)
            throw error
        }
    }
}
