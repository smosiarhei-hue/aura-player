// Path: Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift
//
// Per-pair mashup “AI” style: timings and depths for vocal↔instrumental layering
// are derived from MixPlanner archetypes + TrackProfile cues when available,
// otherwise from structural heuristics of the two durations. Live PlayerCore
// applies this during AutoMix Mashup without DualDeck V2 ownership.

import Foundation
import MixModels

public struct MashupLiveStyle: Sendable, Equatable {
    /// Progress (0…1) where outgoing bass is mostly gone.
    public var bassSwapAt: Double
    /// Progress where outgoing vocals still hold (end of hold window).
    public var vocalHoldUntil: Double
    /// Progress where incoming vocal pocket opens (start of soft reveal).
    public var vocalPocketUntil: Double
    /// How long outgoing volume stays high before the fast fade (0…1).
    public var outgoingVolumeHold: Double
    /// Delay before incoming volume rises (0…1).
    public var incomingVolumeLag: Double
    /// EQ depth multipliers (clamped later to ±15 dB).
    public var bassDepth: Float
    public var vocalPocketDepth: Float
    public var hpfDepth: Float
    public var bodyLift: Float
    /// Soft rate / pitch micro-moves on native decks (cents / rate delta).
    public var outgoingPitchCents: Float
    public var incomingPitchCents: Float
    public var outgoingRateDelta: Float
    public var incomingRateDelta: Float
    public var reason: String
    public var archetypeName: String

    public static let fallback = MashupLiveStyle(
        bassSwapAt: 0.32,
        vocalHoldUntil: 0.50,
        vocalPocketUntil: 0.78,
        outgoingVolumeHold: 0.42,
        incomingVolumeLag: 0.18,
        bassDepth: 1.0,
        vocalPocketDepth: 1.0,
        hpfDepth: 1.0,
        bodyLift: 1.0,
        outgoingPitchCents: 0,
        incomingPitchCents: 0,
        outgoingRateDelta: 0,
        incomingRateDelta: 0,
        reason: "Default mashup style",
        archetypeName: "dropSwap"
    )

    public init(
        bassSwapAt: Double,
        vocalHoldUntil: Double,
        vocalPocketUntil: Double,
        outgoingVolumeHold: Double,
        incomingVolumeLag: Double,
        bassDepth: Float,
        vocalPocketDepth: Float,
        hpfDepth: Float,
        bodyLift: Float,
        outgoingPitchCents: Float,
        incomingPitchCents: Float,
        outgoingRateDelta: Float,
        incomingRateDelta: Float,
        reason: String,
        archetypeName: String
    ) {
        self.bassSwapAt = bassSwapAt
        self.vocalHoldUntil = vocalHoldUntil
        self.vocalPocketUntil = vocalPocketUntil
        self.outgoingVolumeHold = outgoingVolumeHold
        self.incomingVolumeLag = incomingVolumeLag
        self.bassDepth = bassDepth
        self.vocalPocketDepth = vocalPocketDepth
        self.hpfDepth = hpfDepth
        self.bodyLift = bodyLift
        self.outgoingPitchCents = outgoingPitchCents
        self.incomingPitchCents = incomingPitchCents
        self.outgoingRateDelta = outgoingRateDelta
        self.incomingRateDelta = incomingRateDelta
        self.reason = reason
        self.archetypeName = archetypeName
    }

    /// Build a style unique to this track pair.
    public static func resolve(
        plan: TransitionPlan?,
        outgoing: TrackProfile?,
        incoming: TrackProfile?,
        outgoingDuration: Double,
        incomingDuration: Double
    ) -> MashupLiveStyle {
        if let plan, plan.type != .none {
            return fromPlan(plan, outgoing: outgoing, incoming: incoming)
        }
        if let a = outgoing, let b = incoming {
            return fromProfiles(a: a, b: b)
        }
        return fromDurations(outgoingDuration: outgoingDuration, incomingDuration: incomingDuration)
    }

    // MARK: - Plan / profile

    private static func fromPlan(
        _ plan: TransitionPlan,
        outgoing: TrackProfile?,
        incoming: TrackProfile?
    ) -> MashupLiveStyle {
        var style = base(for: plan.archetype)
        style.reason = plan.reason
        style.archetypeName = plan.archetype.rawValue
        if abs(plan.pitchShiftCentsB) >= 1 {
            style.incomingPitchCents = max(-200, min(200, plan.pitchShiftCentsB * 0.35))
        }
        if plan.rateB > 0.01, abs(plan.rateB - 1) > 0.002 {
            style.incomingRateDelta = max(-0.04, min(0.04, plan.rateB - 1))
        }
        if plan.rateA > 0.01, abs(plan.rateA - 1) > 0.002 {
            style.outgoingRateDelta = max(-0.04, min(0.04, plan.rateA - 1))
        }
        refineWithProfiles(&style, a: outgoing, b: incoming)
        return style
    }

    private static func fromProfiles(a: TrackProfile, b: TrackProfile) -> MashupLiveStyle {
        let bpmDiff: Float = (a.bpm > 30 && b.bpm > 30) ? abs(a.bpm - b.bpm) / max(a.bpm, 1) : 0.12
        let harmonic = CamelotCompatibility.match(a.camelotKey, b.camelotKey)
        let archetype: MixTransitionArchetype
        if bpmDiff > 0.12 || !harmonic.isHarmonicallyViable {
            archetype = .echoFreeze
        } else if a.tempoStability >= 0.85, b.tempoStability >= 0.85, harmonic.isNaturallyCompatible {
            archetype = .seamlessLoop
        } else if a.dropsSec.isEmpty && b.dropsSec.isEmpty {
            archetype = .energyWash
        } else {
            archetype = .dropSwap
        }
        var style = base(for: archetype)
        style.reason = "Profile \(archetype.rawValue) · \(Int(a.bpm))→\(Int(b.bpm)) BPM"
        style.archetypeName = archetype.rawValue
        refineWithProfiles(&style, a: a, b: b)
        return style
    }

    private static func fromDurations(outgoingDuration: Double, incomingDuration: Double) -> MashupLiveStyle {
        let out = max(30, outgoingDuration)
        let inn = max(30, incomingDuration)
        let outroHint = min(1, max(0, (out - 120) / 180))
        let introHint = min(1, max(0, (inn - 90) / 150))
        var style = MashupLiveStyle.fallback
        style.vocalHoldUntil = 0.42 + 0.18 * outroHint
        style.vocalPocketUntil = 0.70 + 0.14 * introHint
        style.outgoingVolumeHold = 0.36 + 0.16 * outroHint
        style.incomingVolumeLag = 0.12 + 0.16 * introHint
        style.bodyLift = Float(0.85 + 0.35 * introHint)
        style.vocalPocketDepth = Float(0.9 + 0.25 * introHint)
        style.reason = String(format: "Heuristic pair · out %.0fs / in %.0fs", out, inn)
        style.archetypeName = introHint > 0.45 ? "seamlessLoop" : "dropSwap"
        return style
    }

    private static func base(for archetype: MixTransitionArchetype) -> MashupLiveStyle {
        switch archetype {
        case .dropSwap, .beatStutter, .tapeStop:
            return MashupLiveStyle(
                bassSwapAt: 0.26,
                vocalHoldUntil: 0.48,
                vocalPocketUntil: 0.72,
                outgoingVolumeHold: 0.40,
                incomingVolumeLag: 0.16,
                bassDepth: 1.15,
                vocalPocketDepth: 1.2,
                hpfDepth: 1.15,
                bodyLift: 1.1,
                outgoingPitchCents: -15,
                incomingPitchCents: 0,
                outgoingRateDelta: -0.012,
                incomingRateDelta: 0.018,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .seamlessLoop:
            return MashupLiveStyle(
                bassSwapAt: 0.38,
                vocalHoldUntil: 0.58,
                vocalPocketUntil: 0.84,
                outgoingVolumeHold: 0.52,
                incomingVolumeLag: 0.22,
                bassDepth: 0.85,
                vocalPocketDepth: 1.05,
                hpfDepth: 0.75,
                bodyLift: 1.25,
                outgoingPitchCents: 0,
                incomingPitchCents: 0,
                outgoingRateDelta: 0,
                incomingRateDelta: 0.008,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .echoFreeze, .spaceReverb:
            return MashupLiveStyle(
                bassSwapAt: 0.55,
                vocalHoldUntil: 0.62,
                vocalPocketUntil: 0.88,
                outgoingVolumeHold: 0.58,
                incomingVolumeLag: 0.55,
                bassDepth: 1.05,
                vocalPocketDepth: 0.7,
                hpfDepth: 1.25,
                bodyLift: 0.7,
                outgoingPitchCents: -40,
                incomingPitchCents: 0,
                outgoingRateDelta: -0.03,
                incomingRateDelta: 0,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .energyWash:
            return MashupLiveStyle(
                bassSwapAt: 0.34,
                vocalHoldUntil: 0.46,
                vocalPocketUntil: 0.76,
                outgoingVolumeHold: 0.34,
                incomingVolumeLag: 0.12,
                bassDepth: 0.7,
                vocalPocketDepth: 0.85,
                hpfDepth: 0.8,
                bodyLift: 0.9,
                outgoingPitchCents: 0,
                incomingPitchCents: 0,
                outgoingRateDelta: 0,
                incomingRateDelta: 0,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        }
    }

    private static func refineWithProfiles(
        _ style: inout MashupLiveStyle,
        a: TrackProfile?,
        b: TrackProfile?
    ) {
        if let a {
            let vocalOut = meanTail(a.vocalPresence) ?? meanTail(a.energyCurve) ?? 0.5
            if vocalOut > 0.55 {
                style.vocalHoldUntil = min(0.68, style.vocalHoldUntil + 0.08)
                style.outgoingVolumeHold = min(0.62, style.outgoingVolumeHold + 0.06)
            }
            if a.hasFadeOut || a.endsInSilence {
                style.hpfDepth *= 0.7
                style.outgoingVolumeHold = max(0.22, style.outgoingVolumeHold - 0.08)
            }
            if !a.dropsSec.isEmpty {
                style.bassDepth = min(1.35, style.bassDepth + 0.12)
                style.bassSwapAt = max(0.18, style.bassSwapAt - 0.04)
            }
        }
        if let b {
            let vocalIn = meanHead(b.vocalPresence) ?? meanHead(b.energyCurve) ?? 0.45
            if vocalIn > 0.5 {
                style.vocalPocketDepth = min(1.4, style.vocalPocketDepth + 0.15)
                style.vocalPocketUntil = min(0.92, style.vocalPocketUntil + 0.06)
                style.incomingVolumeLag = min(0.35, style.incomingVolumeLag + 0.05)
                style.bodyLift = min(1.4, style.bodyLift + 0.15)
            }
            if b.mixInSec > 12 {
                style.incomingVolumeLag = min(0.4, style.incomingVolumeLag + 0.08)
                style.bodyLift = min(1.45, style.bodyLift + 0.1)
            }
        }
    }

    private static func meanTail(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let start = Int(Double(values.count) * 0.7)
        let slice = values[start...]
        guard !slice.isEmpty else { return nil }
        return slice.reduce(0, +) / Float(slice.count)
    }

    private static func meanHead(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let end = max(1, Int(Double(values.count) * 0.25))
        let slice = values[..<end]
        return slice.reduce(0, +) / Float(slice.count)
    }

    // MARK: - Volumes (asymmetric vocal↔instrumental bed)

    /// Not equal-power: A stays up while B instrumental sneaks under, then A dumps and B vocals open.
    public func volumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let hold = min(0.7, max(0.15, outgoingVolumeHold))
        let lag = min(0.65, max(0.0, incomingVolumeLag))

        let out: Float
        if p <= hold {
            out = 1.0 - Float(p / max(hold, 0.001)) * 0.12
        } else {
            let t = (p - hold) / max(0.001, 1 - hold)
            out = max(0, 0.88 * Float(cos(t * .pi / 2)))
        }

        let inVol: Float
        if p <= lag {
            inVol = Float(p / max(lag, 0.001)) * 0.28
        } else {
            let t = (p - lag) / max(0.001, 1 - lag)
            inVol = min(1, 0.28 + 0.72 * Float(sin(t * .pi / 2)))
        }
        return (out, inVol)
    }

    public func phaseLabel(progress: Double) -> String {
        let p = min(1, max(0, progress))
        if p < bassSwapAt { return "BASS SWAP" }
        if p < vocalHoldUntil { return "VOCAL HOLD" }
        if p < vocalPocketUntil { return "VOCAL POCKET" }
        return "SOFT REVEAL"
    }
}
