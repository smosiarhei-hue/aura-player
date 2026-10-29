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

/// Live PlayerCore mashup EQ offsets (10 bands: 31…16k ISO ladder).
/// Archetype-shaped sweeps so each pair gets a real mashup filter path, not a
/// flat fade. Gains stay within `EQGainLimits` (±15 dB).
enum MashupLiveEQEnvelope {
    static let bandCount = 10

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

        let shaped: (outgoing: [Float], incoming: [Float])
        switch style.archetypeName {
        case "seamlessLoop":
            shaped = seamlessLoop(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        case "echoFreeze", "spaceReverb":
            shaped = echoFreeze(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        case "energyWash":
            shaped = energyWash(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        case "tapeStop":
            shaped = tapeStop(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        default:
            // dropSwap / beatStutter — sharp bass kill + clear vocal pocket.
            shaped = dropSwap(
                p: p, bassAt: bassAt, holdUntil: holdUntil, pocketUntil: pocketUntil,
                handoff: handoff, bassD: bassD, pocketD: pocketD, hpfD: hpfD, bodyD: bodyD
            )
        }

        guard style.oneVocalConflict else { return shaped }
        return applyOneVocalGate(
            shaped,
            p: p,
            bassAt: bassAt,
            handoff: handoff,
            pocketD: pocketD,
            hpfD: hpfD
        )
    }

    /// Lab ONE VOCAL on the live AVPlayer EQ path (no stem bake available):
    /// A → instrumental shape ASAP; B mid/presence held at floor until LAND.
    private static func applyOneVocalGate(
        _ shaped: (outgoing: [Float], incoming: [Float]),
        p: Double,
        bassAt: Double,
        handoff: Double,
        pocketD: Float,
        hpfD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        var out = shaped.outgoing
        var inn = shaped.incoming
        // A instrumentalize: keep sub/bass, carve 250 Hz–4 kHz hard (Lab mid-vocal cut).
        let outInstr = ramp(p, from: 0.0, to: max(0.1, bassAt * 0.5))
        let outMidCut = clampDB(-15 * hpfD * outInstr)
        let outLeadCut = clampDB(-15 * outInstr)
        if out.count >= 10 {
            out[0] = clampDB(max(out[0], 2.5 * outInstr)) // sub keep
            out[1] = clampDB(max(out[1], 1.5 * outInstr))
            out[2] = clampDB(max(out[2], 1.0 * outInstr))
            out[3] = clampDB(min(out[3], outMidCut * 0.7))
            out[4] = clampDB(min(out[4], outMidCut))
            out[5] = clampDB(min(out[5], outLeadCut))
            out[6] = clampDB(min(out[6], outLeadCut))
            out[7] = clampDB(min(out[7], outLeadCut * 0.85))
            out[8] = clampDB(min(out[8], -8 * outInstr))
            out[9] = clampDB(min(out[9], -8 * outInstr))
        }
        // B instrumental until handoff — then release into dry lead for LAND.
        let inInstr = 1 - ramp(p, from: handoff - 0.02, to: min(0.96, handoff + 0.1))
        let inLeadFloor = clampDB(-15 * max(1.25, pocketD) * inInstr)
        if inn.count >= 10 {
            inn[0] = clampDB(max(inn[0], 1.5 * inInstr)) // kick bed
            inn[1] = clampDB(max(inn[1], 1.0 * inInstr))
            inn[3] = clampDB(min(inn[3], inLeadFloor * 0.45))
            inn[4] = clampDB(min(inn[4], inLeadFloor * 0.55))
            inn[5] = clampDB(min(inn[5], inLeadFloor))
            inn[6] = clampDB(min(inn[6], inLeadFloor))
            inn[7] = clampDB(min(inn[7], inLeadFloor * 0.85))
            inn[8] = clampDB(min(inn[8], inLeadFloor * 0.65))
            inn[9] = clampDB(min(inn[9], inLeadFloor * 0.65))
        }
        return (out, inn)
    }

    /// Apple-style mashup: A bass dies so B kick owns the groove; A stays as
    /// instrumental layer; B vocals + instrumental play together on the grid.
    private static func dropSwap(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        // A: hand bass to B early; carve A toward instrumental outro.
        let outBass = clampDB(-12 * bassD * ramp(p, from: 0.00, to: bassAt * 0.9))
        let outHPFBody = clampDB(-10 * hpfD * ramp(p, from: 0.04, to: holdUntil))
        let outVocalDuck = clampDB(-12 * ramp(p, from: bassAt * 0.4, to: holdUntil))
        let outMidKeep = clampDB(3.0 * bodyD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let outMidDuck = clampDB(-9 * ramp(p, from: handoff, to: 0.98))
        let outAir = clampDB(-8 * ramp(p, from: handoff, to: 1.00))

        // B: bass locks the shared groove; vocals stay audible (light pocket only).
        let inBass = clampDB(-12 * bassD * (1 - ramp(p, from: bassAt * 0.28, to: bassAt + 0.18)))
        let inAirCut = clampDB(-6 * hpfD * (1 - ramp(p, from: 0.05, to: bassAt)))
        let inVocalSoft = clampDB(-6 * pocketD * (1 - ramp(p, from: 0.0, to: bassAt)))
        let inBodyLift = clampDB(5.5 * bodyD * ramp(p, from: 0.02, to: bassAt))
        let inPresence = clampDB(3.2 * (1 - ramp(p, from: handoff, to: pocketUntil)) * ramp(p, from: bassAt, to: handoff))

        return (
            [
                outBass,
                clampDB(outBass * 0.95),
                clampDB(outBass * 0.88),
                clampDB(outHPFBody * 0.7 + outMidKeep * 0.35 + outMidDuck * 0.25),
                clampDB(outHPFBody + outMidKeep * 0.45 + outMidDuck * 0.35),
                clampDB(outVocalDuck + outMidKeep * 0.55 + outMidDuck * 0.25),
                clampDB(outVocalDuck * 0.9 + outMidDuck * 0.25),
                clampDB(outVocalDuck * 0.85 + outMidDuck * 0.2),
                clampDB(outAir * 0.85),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.95),
                clampDB(inBass * 0.88),
                clampDB(inBodyLift * 0.7),
                clampDB(inBodyLift),
                clampDB(inVocalSoft * 0.55 + inPresence * 0.35),
                clampDB(inVocalSoft * 0.4 + inPresence * 0.7),
                clampDB(inVocalSoft * 0.35 + inPresence),
                clampDB(inAirCut * 0.85),
                inAirCut
            ]
        )
    }

    /// Soft dual-layer: shared grid, early bass from B, both mids audible together.
    private static func seamlessLoop(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let outBass = clampDB(-13 * bassD * ramp(p, from: 0.04, to: bassAt))
        let outHPFBody = clampDB(-6 * hpfD * ramp(p, from: 0.10, to: holdUntil))
        let outVocalDuck = clampDB(-8 * ramp(p, from: holdUntil * 0.6, to: handoff))
        let outAir = clampDB(-5 * ramp(p, from: pocketUntil * 0.9, to: 1.00))

        let inBass = clampDB(-12 * bassD * (1 - ramp(p, from: bassAt * 0.4, to: bassAt + 0.15)))
        // Co-sing / mashup: keep B vocals mostly open.
        let inVocalSoft = clampDB(-4 * pocketD * (1 - ramp(p, from: 0.0, to: bassAt)))
        let inBodyLift = clampDB(4.0 * bodyD * ramp(p, from: 0.03, to: bassAt))
        let inAirCut = clampDB(-4 * hpfD * (1 - ramp(p, from: 0.05, to: bassAt)))

        return (
            [
                outBass,
                clampDB(outBass * 0.9),
                clampDB(outBass * 0.75),
                clampDB(outHPFBody * 0.7),
                clampDB(outHPFBody),
                outVocalDuck,
                clampDB(outVocalDuck * 0.85),
                clampDB(outVocalDuck * 0.75),
                clampDB(outAir * 0.85),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.9),
                clampDB(inBass * 0.75),
                clampDB(inBodyLift * 0.7),
                inBodyLift,
                clampDB(inVocalSoft * 0.5),
                clampDB(inVocalSoft * 0.75),
                inVocalSoft,
                clampDB(inAirCut * 0.85),
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

        let inBass = clampDB(-12 * bassD * (1 - ramp(p, from: lateBass, to: pocketUntil)))
        let inVocalPocket = clampDB(-13 * pocketD * (1 - ramp(p, from: handoff, to: pocketUntil)))
        let inBodyLift = clampDB(2.5 * bodyD * ramp(p, from: 0.2, to: lateBass) * (1 - ramp(p, from: handoff, to: pocketUntil)))
        let inAirCut = clampDB(-14 * hpfD * (1 - ramp(p, from: holdUntil, to: 0.96)))

        return (
            [
                outBass,
                clampDB(outBass * 0.9 + outBody * 0.15),
                clampDB(outBass * 0.8 + outBody * 0.25),
                clampDB(outMidCut * 0.7 + outBody * 0.7),
                clampDB(outMidCut + outBody),
                clampDB(outVocalHold + outVocalDump + outMidCut * 0.4),
                clampDB(outVocalHold * 0.85 + outVocalDump * 0.9),
                clampDB(outVocalHold * 0.7 + outVocalDump),
                clampDB(outAir * 0.9),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.92),
                clampDB(inBass * 0.85),
                clampDB(inBodyLift * 0.7),
                inBodyLift,
                clampDB(inVocalPocket * 0.85),
                clampDB(inVocalPocket * 0.95),
                inVocalPocket,
                clampDB(inAirCut * 0.9),
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
                clampDB(outBass * 0.9 + outHPF * 0.1),
                clampDB(outBass * 0.75 + outHPF * 0.2),
                clampDB(outHPF * 0.7),
                clampDB(outHPF * 0.85),
                outVocal,
                clampDB(outVocal * 0.95 + outHPF * 0.15),
                clampDB(outVocal * 0.9 + outHPF * 0.25),
                clampDB(outAir * 0.9),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.9),
                clampDB(inBass * 0.75),
                clampDB(inBody * 0.7 + inLPF * 0.25),
                clampDB(inBody + inLPF * 0.35),
                clampDB(inVocalPocket * 0.85 + inLPF * 0.25),
                clampDB(inVocalPocket * 0.95 + inLPF * 0.2),
                clampDB(inVocalPocket + inLPF * 0.15),
                clampDB(inLPF * 0.75),
                clampDB(inLPF * 0.7)
            ]
        )
    }

    /// Tape-stop feel: progressive HPF + body collapse on A into the handoff.
    private static func tapeStop(
        p: Double, bassAt: Double, holdUntil: Double, pocketUntil: Double, handoff: Double,
        bassD: Float, pocketD: Float, hpfD: Float, bodyD: Float
    ) -> (outgoing: [Float], incoming: [Float]) {
        let outBass = clampDB(-12 * bassD * ramp(p, from: 0.00, to: bassAt * 0.9))
        let outCollapse = clampDB(-15 * hpfD * ramp(p, from: 0.10, to: handoff))
        let outVocal = clampDB(3.0 * (1 - ramp(p, from: holdUntil * 0.4, to: holdUntil))
            - 15 * ramp(p, from: holdUntil, to: pocketUntil))
        let outAir = clampDB(-14 * ramp(p, from: handoff * 0.8, to: 1.00))

        let inBass = clampDB(-12 * bassD * (1 - ramp(p, from: bassAt * 0.28, to: bassAt + 0.18)))
        let inVocalPocket = clampDB(-14 * pocketD * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inBody = clampDB(4.0 * bodyD * ramp(p, from: 0.05, to: bassAt) * (1 - ramp(p, from: holdUntil, to: pocketUntil)))
        let inAirCut = clampDB(-10 * (1 - ramp(p, from: holdUntil, to: 0.94)))

        return (
            [
                outBass,
                clampDB(outBass * 0.95 + outCollapse * 0.1),
                clampDB(outBass * 0.9 + outCollapse * 0.2),
                clampDB(outCollapse * 0.85),
                clampDB(outCollapse),
                clampDB(outVocal + outCollapse * 0.35),
                clampDB(outVocal * 0.9 + outCollapse * 0.35),
                clampDB(outVocal * 0.85 + outCollapse * 0.4),
                clampDB(outAir * 0.9),
                outAir
            ],
            [
                inBass,
                clampDB(inBass * 0.95),
                clampDB(inBass * 0.85),
                clampDB(inBody * 0.7),
                inBody,
                clampDB(inVocalPocket * 0.88),
                clampDB(inVocalPocket * 0.95),
                inVocalPocket,
                clampDB(inAirCut * 0.9),
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
