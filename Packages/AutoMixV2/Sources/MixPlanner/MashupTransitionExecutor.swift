// Path: Packages/AutoMixV2/Sources/MixPlanner/MashupTransitionExecutor.swift
//
// Executes a MixPlanner TransitionPlan as a DJ mashup on dual decks:
// bass swap, vocal ducking, HP/LP sweeps, echo-out, rate ramp and volumes.
// The live PlayerCore path can mirror a lighter subset via EQ offsets;
// this executor is the full DualDeck timeline used by AutoMix V2 / Neuro handoff.

import Foundation
import MixModels

public enum MashupTransitionError: Error, Sendable, Equatable {
    case invalidPlan
    case emptyTimeline
}

/// Minimal audio surface needed to run mashup FX without depending on AVFoundation here.
public protocol MashupTransitionAudio: Sendable {
    func applyEffect(_ kind: FxKind, value: Float, param: Float?, bpm: Float, to deck: Deck) async
    func setRate(_ rate: Float, for deck: Deck) async
    func setPitchCents(_ cents: Float, for deck: Deck) async
    func resetEffects(_ deck: Deck, preservingRate: Bool) async
}

public struct MashupTransitionExecutor: Sendable {
    private let audio: any MashupTransitionAudio
    private let clock: ContinuousClock
    private let tickSeconds: Double

    public init(audio: any MashupTransitionAudio, tickSeconds: Double = 0.05) {
        self.audio = audio
        self.clock = ContinuousClock()
        self.tickSeconds = max(0.01, tickSeconds)
    }

    /// Duration of the planned mashup in seconds (bars → time via target BPM).
    public static func durationSeconds(for plan: TransitionPlan) -> Double {
        guard plan.bars.isFinite, plan.bars > 0 else { return 0 }
        if plan.tempoTargetBPM > 30 {
            return EffectAutomation.seconds(atBar: plan.bars, bpm: plan.tempoTargetBPM)
        }
        // Crossfade fallback plans encode seconds directly in `bars`.
        return max(0, plan.bars)
    }

    public func execute(_ plan: TransitionPlan) async throws {
        guard plan.type != .none else { throw MashupTransitionError.invalidPlan }
        let duration = Self.durationSeconds(for: plan)
        guard duration > 0 else { throw MashupTransitionError.emptyTimeline }

        let bpm = plan.tempoTargetBPM > 30 ? plan.tempoTargetBPM : 120
        await audio.resetEffects(.a, preservingRate: false)
        await audio.resetEffects(.b, preservingRate: false)
        await audio.setRate(plan.rateA, for: .a)
        await audio.setRate(plan.rateB, for: .b)
        if abs(plan.pitchShiftCentsB) >= 1 {
            await audio.setPitchCents(plan.pitchShiftCentsB, for: .b)
        }

        // Seed initial FX values at bar 0 so bass-kill / volume floors are audible immediately.
        try await applyActiveEvents(plan: plan, bar: 0, bpm: bpm)

        var elapsed = 0.0
        while elapsed < duration {
            try Task.checkCancellation()
            let bar: Double
            if plan.tempoTargetBPM > 30 {
                bar = EffectAutomation.bar(atSeconds: elapsed, bpm: bpm)
            } else {
                bar = elapsed
            }
            try await applyActiveEvents(plan: plan, bar: bar, bpm: bpm)
            let step = min(tickSeconds, duration - elapsed)
            try await clock.sleep(for: .seconds(step))
            elapsed += step
        }

        // Snap to final values and leave incoming deck clean for promotion.
        try await applyActiveEvents(plan: plan, bar: plan.bars, bpm: bpm)
        await audio.setRate(1, for: .b)
        await audio.setPitchCents(0, for: .b)
        await audio.resetEffects(.b, preservingRate: true)
        await audio.applyEffect(.volume, value: -60, param: nil, bpm: bpm, to: .a)
        await audio.applyEffect(.volume, value: 0, param: nil, bpm: bpm, to: .b)
    }

    private func applyActiveEvents(plan: TransitionPlan, bar: Double, bpm: Float) async throws {
        for event in plan.fx {
            guard let value = EffectAutomation.value(for: event, atBar: bar) else { continue }
            switch event.kind {
            case .volume, .highPass, .lowPass, .bassKill, .bassOn, .echoOut,
                 .reverbWash, .tapeStop, .stutter, .vocalDucking:
                await audio.applyEffect(event.kind, value: value, param: event.param, bpm: bpm, to: event.target)
            case .rateRamp:
                await audio.setRate(value, for: event.target)
            }
        }
    }
}
