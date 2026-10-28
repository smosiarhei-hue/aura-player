// Path: Sonivo/MixPlanRealtimeTransitionRunner.swift
//
// Runs a MixPlanner mashup TransitionPlan on DualDeckAudioEngine.
// Used when AutoMix V2 / Neuro ownership is active; PlayerCore mirrors a
// vocal↔instrumental mashup via MashupLiveEQEnvelope + MashupLiveStyle
// for the live path (per-track algorithmic envelopes).

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
/// Timings/depths come from `MashupLiveStyle` so each track pair gets its own shape.
/// Gains stay within `EQGainLimits` (±15 dB).
enum MashupLiveEQEnvelope {
    static let bandCount = 6

    private static func ramp(_ progress: Double, from start: Double, to end: Double) -> Float {
        guard end > start else { return progress >= end ? 1 : 0 }
        return Float(min(1, max(0, (progress - start) / (end - start))))
    }

    private static func clampDB(_ value: Float) -> Float {
        max(-15, min(15, value))
    }

    static func offsets(
        progress: Double,
        style: MashupLiveStyle = .fallback
    ) -> (outgoing: [Float], incoming: [Float]) {
        let p = min(1, max(0, progress))
        let bassAt = min(0.7, max(0.12, style.bassSwapAt))
        let holdUntil = min(0.75, max(bassAt + 0.05, style.vocalHoldUntil))
        let pocketUntil = min(0.95, max(holdUntil + 0.08, style.vocalPocketUntil))
        let bassD = max(0.5, style.bassDepth)
        let pocketD = max(0.5, style.vocalPocketDepth)
        let hpfD = max(0.5, style.hpfDepth)
        let bodyD = max(0.4, style.bodyLift)

        // --- Outgoing: kill bass, hold vocals, HPF riser, then duck mid/vocal ---
        let outBass = clampDB(-15 * bassD * ramp(p, from: 0.00, to: bassAt))
        let outHPFBody = clampDB(-12 * hpfD * ramp(p, from: 0.06, to: holdUntil))
        let outHPFMid = clampDB(-11 * hpfD * ramp(p, from: bassAt * 0.7, to: pocketUntil))
        let outVocalHold = clampDB(3.2 * (1 - ramp(p, from: holdUntil * 0.55, to: holdUntil)))
        let outVocalDuck = clampDB(-14 * ramp(p, from: holdUntil, to: min(1, pocketUntil + 0.12)))
        let outVocal = clampDB(outVocalHold + outVocalDuck)
        let outMidDuck = clampDB(-10 * ramp(p, from: holdUntil, to: 0.96))
        let outAir = clampDB(-8 * ramp(p, from: pocketUntil * 0.85, to: 1.00))

        // --- Incoming: instrumental bed under pocket, then bass + vocal soft reveal ---
        let inBass = clampDB(-15 * bassD * (1 - ramp(p, from: bassAt, to: pocketUntil)))
        let inAirCut = clampDB(-12 * hpfD * (1 - ramp(p, from: holdUntil * 0.7, to: 0.94)))
        let inPresenceOpen = clampDB(-10 * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inVocalPocket = clampDB(-15 * pocketD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inBodyLift = clampDB(
            4.0 * bodyD * ramp(p, from: 0.03, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil))
        )
        let inMidDuck = clampDB(
            -8 * ramp(p, from: 0.15, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil))
        )

        return (
            [
                outBass,
                clampDB(outBass * 0.88),
                clampDB(outHPFBody + outMidDuck * 0.55),
                clampDB(outVocal + outHPFMid * 0.45 + outMidDuck * 0.35),
                clampDB(outVocal * 0.92 + outHPFMid * 0.30),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.88),
                clampDB(inBodyLift + inMidDuck),
                clampDB(inVocalPocket * 0.88 + inMidDuck * 0.45),
                clampDB(inVocalPocket + inPresenceOpen * 0.55),
                inAirCut
            ]
        )
    }

    static func isAudible(progress: Double, style: MashupLiveStyle = .fallback) -> Bool {
        let shaped = offsets(progress: progress, style: style)
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
