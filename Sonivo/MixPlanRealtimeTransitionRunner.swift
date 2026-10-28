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
/// Archetype-shaped sweeps so each pair gets a real mashup filter path, not a
/// flat fade. Gains stay within `EQGainLimits` (±15 dB).
enum MashupLiveEQEnvelope {
    static let bandCount = 6

    private static func ramp(_ progress: Double, from start: Double, to end: Double) -> Float {
        guard end > start else { return progress >= end ? 1 : 0 }
        return MashupLiveStyle.smoothstep((progress - start) / (end - start))
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
        let handoff = min(0.85, max(holdUntil, style.handoffAt))
        let bassD = max(0.5, style.bassDepth)
        let pocketD = max(0.5, style.vocalPocketDepth)
        let hpfD = max(0.5, style.hpfDepth)
        let bodyD = max(0.4, style.bodyLift)

        switch style.archetypeName {
        case "seamlessLoop":
            return seamlessLoop(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        case "echoFreeze", "spaceReverb":
            return echoFreeze(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        case "energyWash":
            return energyWash(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        case "tapeStop":
            return tapeStop(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        default:
            // dropSwap / beatStutter — sharp bass kill + clear vocal pocket.
            return dropSwap(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        }
    }

    /// Classic DJ drop: kill A lows fast, keep A vocal, B = instrumental bed → vocal open.
    private static func dropSwap(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let outBass = clampDB(-15 * bassD * ramp(p, from: 0.00, to: bassAt * 0.85))
        let outHPFBody = clampDB(-13 * hpfD * ramp(p, from: 0.04, to: holdUntil))
        let outHPFMid = clampDB(-12 * hpfD * ramp(p, from: bassAt * 0.55, to: pocketUntil))
        let outVocalHold = clampDB(4.2 * (1 - ramp(p, from: holdUntil * 0.45, to: holdUntil)))
        let outVocalDuck = clampDB(-15 * ramp(p, from: holdUntil, to: min(1, pocketUntil + 0.10)))
        let outVocal = clampDB(outVocalHold + outVocalDuck)
        let outMidDuck = clampDB(-11 * ramp(p, from: holdUntil, to: 0.96))
        let outAir = clampDB(-9 * ramp(p, from: handoff, to: 1.00))

        let inBass = clampDB(-15 * bassD * (1 - ramp(p, from: bassAt, to: handoff + 0.12)))
        let inAirCut = clampDB(-11 * hpfD * (1 - ramp(p, from: holdUntil * 0.65, to: 0.94)))
        let inPresenceOpen = clampDB(-9 * (1 - ramp(p, from: handoff, to: pocketUntil)))
        let inVocalPocket = clampDB(-15 * pocketD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inBodyLift = clampDB(
            5.0 * bodyD * ramp(p, from: 0.02, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil))
        )
        let inMidDuck = clampDB(
            -9 * ramp(p, from: 0.10, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil))
        )

        return (
            [
                outBass,
                clampDB(outBass * 0.90),
                clampDB(outHPFBody + outMidDuck * 0.55),
                clampDB(outVocal + outHPFMid * 0.40 + outMidDuck * 0.30),
                clampDB(outVocal * 0.95 + outHPFMid * 0.28),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.90),
                clampDB(inBodyLift + inMidDuck),
                clampDB(inVocalPocket * 0.90 + inMidDuck * 0.40),
                clampDB(inVocalPocket + inPresenceOpen * 0.60),
                inAirCut
            ]
        )
    }

    /// Soft HPF + brief co-singing window (compatible keys / same BPM).
    private static func seamlessLoop(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let outBass = clampDB(-11 * bassD * ramp(p, from: 0.08, to: bassAt))
        let outHPFBody = clampDB(-7 * hpfD * ramp(p, from: 0.12, to: holdUntil))
        let outVocalHold = clampDB(2.4 * (1 - ramp(p, from: holdUntil * 0.7, to: handoff)))
        let outVocalDuck = clampDB(-10 * ramp(p, from: handoff, to: pocketUntil))
        let outVocal = clampDB(outVocalHold + outVocalDuck)
        let outAir = clampDB(-5 * ramp(p, from: pocketUntil * 0.9, to: 1.00))

        let inBass = clampDB(-10 * bassD * (1 - ramp(p, from: bassAt * 0.85, to: pocketUntil)))
        // Soft co-sing: lighter vocal pocket so both voices share a beat.
        let inVocalPocket = clampDB(-9 * pocketD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inBodyLift = clampDB(3.5 * bodyD * ramp(p, from: 0.05, to: bassAt) * (1 - ramp(p, from: handoff, to: pocketUntil)))
        let inAirCut = clampDB(-6 * hpfD * (1 - ramp(p, from: holdUntil, to: 0.92)))

        return (
            [
                outBass,
                clampDB(outBass * 0.75),
                clampDB(outHPFBody),
                outVocal,
                clampDB(outVocal * 0.85),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.75),
                inBodyLift,
                clampDB(inVocalPocket * 0.75),
                inVocalPocket,
                inAirCut
            ]
        )
    }

    /// Delayed A dump with aggressive mid cut — space for echo/freeze feel.
    private static func echoFreeze(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let lateBass = max(bassAt, handoff - 0.18)
        let outBass = clampDB(-14 * bassD * ramp(p, from: lateBass * 0.5, to: lateBass))
        let outMidCut = clampDB(-15 * hpfD * ramp(p, from: holdUntil * 0.6, to: handoff))
        let outVocalHold = clampDB(2.0 * (1 - ramp(p, from: holdUntil, to: handoff)))
        let outVocalDump = clampDB(-15 * ramp(p, from: handoff, to: min(1, pocketUntil)))
        let outAir = clampDB(-12 * ramp(p, from: handoff, to: 1.00))
        let outBody = clampDB(-13 * hpfD * ramp(p, from: lateBass, to: pocketUntil))

        let inBass = clampDB(-15 * bassD * (1 - ramp(p, from: lateBass, to: pocketUntil)))
        let inVocalPocket = clampDB(-13 * pocketD * (1 - ramp(p, from: handoff, to: pocketUntil)))
        let inBodyLift = clampDB(2.5 * bodyD * ramp(p, from: 0.2, to: lateBass) * (1 - ramp(p, from: handoff, to: pocketUntil)))
        let inAirCut = clampDB(-14 * hpfD * (1 - ramp(p, from: holdUntil, to: 0.96)))

        return (
            [
                outBass,
                clampDB(outBass * 0.85 + outBody * 0.25),
                clampDB(outMidCut + outBody),
                clampDB(outVocalHold + outVocalDump + outMidCut * 0.4),
                clampDB(outVocalHold * 0.7 + outVocalDump),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.88),
                inBodyLift,
                clampDB(inVocalPocket * 0.85),
                inVocalPocket,
                inAirCut
            ]
        )
    }

    /// Balanced energy wash — filter sweep both ways, not equal-power dual vocals.
    private static func energyWash(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let outBass = clampDB(-12 * bassD * ramp(p, from: 0.05, to: bassAt))
        let outHPF = clampDB(-14 * hpfD * ramp(p, from: 0.08, to: pocketUntil))
        let outVocal = clampDB(2.0 * (1 - ramp(p, from: holdUntil * 0.5, to: handoff))
            - 12 * ramp(p, from: handoff, to: 1.0))
        let outAir = clampDB(-7 * ramp(p, from: handoff, to: 1.00))

        let inBass = clampDB(-12 * bassD * (1 - ramp(p, from: bassAt, to: pocketUntil)))
        let inLPF = clampDB(-13 * hpfD * (1 - ramp(p, from: 0.05, to: handoff)))
        let inVocalPocket = clampDB(-12 * pocketD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inBody = clampDB(4.5 * bodyD * ramp(p, from: 0.04, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil)))

        return (
            [
                outBass,
                clampDB(outBass * 0.8 + outHPF * 0.2),
                clampDB(outHPF * 0.85),
                outVocal,
                clampDB(outVocal * 0.9 + outHPF * 0.25),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.8),
                clampDB(inBody + inLPF * 0.35),
                clampDB(inVocalPocket * 0.85 + inLPF * 0.25),
                clampDB(inVocalPocket + inLPF * 0.15),
                clampDB(inLPF * 0.7)
            ]
        )
    }

    /// Tape-stop feel: progressive HPF + body collapse on A into the handoff.
    private static func tapeStop(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let outBass = clampDB(-15 * bassD * ramp(p, from: 0.00, to: bassAt))
        let outCollapse = clampDB(-15 * hpfD * ramp(p, from: 0.10, to: handoff))
        let outVocal = clampDB(3.0 * (1 - ramp(p, from: holdUntil * 0.4, to: holdUntil))
            - 15 * ramp(p, from: holdUntil, to: pocketUntil))
        let outAir = clampDB(-14 * ramp(p, from: handoff * 0.8, to: 1.00))

        let inBass = clampDB(-15 * bassD * (1 - ramp(p, from: bassAt, to: pocketUntil)))
        let inVocalPocket = clampDB(-14 * pocketD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inBody = clampDB(4.0 * bodyD * ramp(p, from: 0.05, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inAirCut = clampDB(-10 * (1 - ramp(p, from: holdUntil, to: 0.94)))

        return (
            [
                outBass,
                clampDB(outBass * 0.92 + outCollapse * 0.2),
                clampDB(outCollapse),
                clampDB(outVocal + outCollapse * 0.35),
                clampDB(outVocal * 0.85 + outCollapse * 0.4),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.9),
                inBody,
                clampDB(inVocalPocket * 0.88),
                inVocalPocket,
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
