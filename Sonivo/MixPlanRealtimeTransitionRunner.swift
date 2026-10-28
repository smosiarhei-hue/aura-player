// Path: Sonivo/MixPlanRealtimeTransitionRunner.swift
//
// Runs a MixPlanner mashup TransitionPlan on DualDeckAudioEngine.
// Used when AutoMix V2 / Neuro ownership is active; PlayerCore mirrors a
// lighter bass-swap mashup via MashupLiveEQEnvelope for the legacy path.

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
/// Volumes stay on CrossfadeCurve; this only shapes bass swap + vocal pocket + soft HPF proxy.
enum MashupLiveEQEnvelope {
    static func offsets(progress: Double) -> (outgoing: [Float], incoming: [Float]) {
        let p = min(1, max(0, progress))
        let outBass = Float(-32 * min(1, p / 0.40))
        let inBass = Float(-32 * max(0, 1 - max(0, p - 0.35) / 0.40))
        let outBody = Float(-10 * max(0, (p - 0.15) / 0.85))
        let inVocal = Float(-7 * max(0, 1 - p / 0.45))
        return (
            [outBass, outBass * 0.75, outBody, 0, 0, 0],
            [inBass, inBass * 0.75, 0, inVocal, 0, 0]
        )
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
