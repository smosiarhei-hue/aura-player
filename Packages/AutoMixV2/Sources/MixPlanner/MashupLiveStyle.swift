// Path: Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift
//
// Per-pair live mashup: real BPM beatmatch (rateA/rateB) + vocal↔instrumental
// layering timed to the MixPlanner handoff — not cosmetic EQ-only effects.

import Foundation
import MixModels

public struct MashupLiveStyle: Sendable, Equatable {
    /// Progress (0…1) where outgoing bass is mostly gone / B bass comes in.
    public var bassSwapAt: Double
    /// Progress where outgoing vocals still hold (end of hold window).
    public var vocalHoldUntil: Double
    /// Progress where incoming vocal pocket opens (start of soft reveal).
    public var vocalPocketUntil: Double
    /// Musical handoff (drop / phrase) — usually mid-window when beatmatched.
    public var handoffAt: Double
    /// How long outgoing volume stays high before the fast fade (0…1).
    public var outgoingVolumeHold: Double
    /// Delay before incoming volume rises (0…1) — instrumental bed under A vocals.
    public var incomingVolumeLag: Double
    public var bassDepth: Float
    public var vocalPocketDepth: Float
    public var hpfDepth: Float
    public var bodyLift: Float
    /// Held playback rates during the mashup window (1.0 = natural tempo).
    public var rateA: Float
    public var rateB: Float
    /// Camelot key compensation on B (cents), held then released.
    public var pitchCentsB: Float
    public var targetBPM: Float
    public var isBeatmatched: Bool
    public var reason: String
    public var archetypeName: String

    public static let fallback = MashupLiveStyle(
        bassSwapAt: 0.32,
        vocalHoldUntil: 0.50,
        vocalPocketUntil: 0.78,
        handoffAt: 0.50,
        outgoingVolumeHold: 0.42,
        incomingVolumeLag: 0.18,
        bassDepth: 1.0,
        vocalPocketDepth: 1.0,
        hpfDepth: 1.0,
        bodyLift: 1.0,
        rateA: 1,
        rateB: 1,
        pitchCentsB: 0,
        targetBPM: 0,
        isBeatmatched: false,
        reason: "Default mashup style",
        archetypeName: "dropSwap"
    )

    public init(
        bassSwapAt: Double,
        vocalHoldUntil: Double,
        vocalPocketUntil: Double,
        handoffAt: Double,
        outgoingVolumeHold: Double,
        incomingVolumeLag: Double,
        bassDepth: Float,
        vocalPocketDepth: Float,
        hpfDepth: Float,
        bodyLift: Float,
        rateA: Float,
        rateB: Float,
        pitchCentsB: Float,
        targetBPM: Float,
        isBeatmatched: Bool,
        reason: String,
        archetypeName: String
    ) {
        self.bassSwapAt = bassSwapAt
        self.vocalHoldUntil = vocalHoldUntil
        self.vocalPocketUntil = vocalPocketUntil
        self.handoffAt = handoffAt
        self.outgoingVolumeHold = outgoingVolumeHold
        self.incomingVolumeLag = incomingVolumeLag
        self.bassDepth = bassDepth
        self.vocalPocketDepth = vocalPocketDepth
        self.hpfDepth = hpfDepth
        self.bodyLift = bodyLift
        self.rateA = rateA
        self.rateB = rateB
        self.pitchCentsB = pitchCentsB
        self.targetBPM = targetBPM
        self.isBeatmatched = isBeatmatched
        self.reason = reason
        self.archetypeName = archetypeName
    }

    /// Build a style unique to this track pair (BPM + cues when profiles exist).
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

    // MARK: - Beatmatch rates during the window

    /// Hold `rateA`/`rateB` for most of the blend, settle both to 1.0 in the last stretch
    /// (same idea as MixPlanner `rateRamp` into natural tempo after the handoff).
    public func playbackRates(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let settleStart = max(handoffAt, 0.72)
        let settle: Float
        if p <= settleStart {
            settle = 0
        } else {
            settle = Float(min(1, (p - settleStart) / max(0.001, 1 - settleStart)))
        }
        let out = rateA + (1 - rateA) * settle
        let inn = rateB + (1 - rateB) * settle
        return (
            max(0.84, min(1.16, out)),
            max(0.84, min(1.16, inn))
        )
    }

    public func pitchCents(progress: Double) -> Float {
        let p = min(1, max(0, progress))
        // Keep key shift until handoff, then ease out.
        if p <= handoffAt { return pitchCentsB }
        let t = Float((p - handoffAt) / max(0.001, 1 - handoffAt))
        return pitchCentsB * (1 - t)
    }

    // MARK: - Volumes (A vocal over B instrumental bed → handoff → B vocal)

    public func volumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let hold = min(0.72, max(0.18, outgoingVolumeHold))
        let lag = min(0.55, max(0.05, incomingVolumeLag))
        let handoff = min(0.85, max(hold, handoffAt))

        let out: Float
        if p <= hold {
            // Keep A loud so vocals stay on top of the beatmatched bed.
            out = 1.0 - Float(p / max(hold, 0.001)) * 0.10
        } else if p <= handoff {
            let t = (p - hold) / max(0.001, handoff - hold)
            out = max(0.35, 0.90 * Float(cos(t * .pi / 2)))
        } else {
            let t = (p - handoff) / max(0.001, 1 - handoff)
            out = max(0, 0.35 * Float(cos(t * .pi / 2)))
        }

        let inVol: Float
        if p <= lag {
            // Quiet instrumental bed under A vocals (same BPM when beatmatched).
            inVol = Float(p / max(lag, 0.001)) * 0.32
        } else if p <= handoff {
            let t = (p - lag) / max(0.001, handoff - lag)
            inVol = min(0.85, 0.32 + 0.53 * Float(sin(t * .pi / 2)))
        } else {
            let t = (p - handoff) / max(0.001, 1 - handoff)
            inVol = min(1, 0.85 + 0.15 * Float(sin(t * .pi / 2)))
        }
        return (out, inVol)
    }

    public func phaseLabel(progress: Double) -> String {
        let p = min(1, max(0, progress))
        if isBeatmatched, p < min(0.22, bassSwapAt) {
            return String(format: "BEATMATCH %.0f", targetBPM)
        }
        if p < bassSwapAt { return "BASS SWAP" }
        if p < vocalHoldUntil { return "VOCAL × INSTR" }
        if p < handoffAt { return "HANDOFF" }
        if p < vocalPocketUntil { return "VOCAL POCKET" }
        return "SOFT REVEAL"
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
        let matched = abs(plan.rateA - 1) > 0.002 || abs(plan.rateB - 1) > 0.002 || plan.tempoTargetBPM > 30
        style.isBeatmatched = matched && plan.type != .crossfade && plan.type != .none
        style.rateA = clampRate(plan.rateA)
        style.rateB = clampRate(plan.rateB)
        style.pitchCentsB = max(-200, min(200, plan.pitchShiftCentsB))
        style.targetBPM = plan.tempoTargetBPM > 30 ? plan.tempoTargetBPM : 0
        // Handoff at half the planned bars (drop / phrase center).
        style.handoffAt = 0.48
        style.bassSwapAt = min(style.handoffAt, max(0.18, style.handoffAt - 0.18))
        style.vocalHoldUntil = min(0.72, style.handoffAt + 0.04)
        style.vocalPocketUntil = min(0.92, style.handoffAt + 0.28)
        style.outgoingVolumeHold = min(0.6, style.handoffAt - 0.06)
        style.incomingVolumeLag = max(0.08, style.bassSwapAt * 0.55)
        refineWithProfiles(&style, a: outgoing, b: incoming)
        if style.isBeatmatched {
            style.reason = "Beatmatch \(Int(round(style.targetBPM))) BPM · \(plan.reason)"
        }
        return style
    }

    private static func fromProfiles(a: TrackProfile, b: TrackProfile) -> MashupLiveStyle {
        let bpmDiff: Float = (a.bpm > 30 && b.bpm > 30) ? abs(a.bpm - b.bpm) / max(a.bpm, 1) : 1
        let harmonic = CamelotCompatibility.match(a.camelotKey, b.camelotKey)
        let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm)

        let archetype: MixTransitionArchetype
        if tempo == nil || bpmDiff > 0.15 || !harmonic.isHarmonicallyViable {
            archetype = (a.confidence.bpm >= 0.7 && b.confidence.bpm >= 0.7) ? .echoFreeze : .energyWash
        } else if a.tempoStability >= 0.85, b.tempoStability >= 0.85, harmonic.isNaturallyCompatible, bpmDiff <= 0.01 {
            archetype = .seamlessLoop
        } else if a.dropsSec.isEmpty && b.dropsSec.isEmpty {
            archetype = .energyWash
        } else {
            archetype = .dropSwap
        }

        var style = base(for: archetype)
        style.archetypeName = archetype.rawValue
        if let tempo {
            style.isBeatmatched = true
            style.rateA = clampRate(tempo.rateA)
            style.rateB = clampRate(tempo.rateB)
            style.targetBPM = tempo.targetBPM
            style.pitchCentsB = max(-200, min(200, harmonic.pitchShiftCents))
            style.reason = String(
                format: "Beatmatch %.0f BPM · %@ · %d→%d",
                tempo.targetBPM, archetype.rawValue, Int(a.bpm), Int(b.bpm)
            )
        } else {
            style.isBeatmatched = false
            style.reason = "No safe tempo match · \(archetype.rawValue)"
        }
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
        style.handoffAt = 0.48 + 0.06 * outroHint
        style.bodyLift = Float(0.85 + 0.35 * introHint)
        style.vocalPocketDepth = Float(0.9 + 0.25 * introHint)
        style.isBeatmatched = false
        style.rateA = 1
        style.rateB = 1
        style.reason = String(format: "Waiting for BPM analysis · out %.0fs / in %.0fs", out, inn)
        style.archetypeName = introHint > 0.45 ? "seamlessLoop" : "dropSwap"
        return style
    }

    private static func base(for archetype: MixTransitionArchetype) -> MashupLiveStyle {
        switch archetype {
        case .dropSwap, .beatStutter, .tapeStop:
            return MashupLiveStyle(
                bassSwapAt: 0.28,
                vocalHoldUntil: 0.50,
                vocalPocketUntil: 0.78,
                handoffAt: 0.48,
                outgoingVolumeHold: 0.40,
                incomingVolumeLag: 0.14,
                bassDepth: 1.2,
                vocalPocketDepth: 1.25,
                hpfDepth: 1.1,
                bodyLift: 1.2,
                rateA: 1, rateB: 1, pitchCentsB: 0, targetBPM: 0,
                isBeatmatched: false,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .seamlessLoop:
            return MashupLiveStyle(
                bassSwapAt: 0.40,
                vocalHoldUntil: 0.58,
                vocalPocketUntil: 0.86,
                handoffAt: 0.52,
                outgoingVolumeHold: 0.50,
                incomingVolumeLag: 0.20,
                bassDepth: 0.9,
                vocalPocketDepth: 1.1,
                hpfDepth: 0.75,
                bodyLift: 1.3,
                rateA: 1, rateB: 1, pitchCentsB: 0, targetBPM: 0,
                isBeatmatched: false,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .echoFreeze, .spaceReverb:
            return MashupLiveStyle(
                bassSwapAt: 0.58,
                vocalHoldUntil: 0.64,
                vocalPocketUntil: 0.90,
                handoffAt: 0.72,
                outgoingVolumeHold: 0.60,
                incomingVolumeLag: 0.55,
                bassDepth: 1.05,
                vocalPocketDepth: 0.7,
                hpfDepth: 1.25,
                bodyLift: 0.65,
                rateA: 1, rateB: 1, pitchCentsB: 0, targetBPM: 0,
                isBeatmatched: false,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .energyWash:
            return MashupLiveStyle(
                bassSwapAt: 0.34,
                vocalHoldUntil: 0.46,
                vocalPocketUntil: 0.76,
                handoffAt: 0.50,
                outgoingVolumeHold: 0.34,
                incomingVolumeLag: 0.12,
                bassDepth: 0.75,
                vocalPocketDepth: 0.9,
                hpfDepth: 0.85,
                bodyLift: 0.95,
                rateA: 1, rateB: 1, pitchCentsB: 0, targetBPM: 0,
                isBeatmatched: false,
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
                style.vocalHoldUntil = min(0.70, style.vocalHoldUntil + 0.08)
                style.outgoingVolumeHold = min(0.62, style.outgoingVolumeHold + 0.06)
            }
            if a.hasFadeOut || a.endsInSilence {
                style.hpfDepth *= 0.7
                style.outgoingVolumeHold = max(0.22, style.outgoingVolumeHold - 0.08)
            }
            if !a.dropsSec.isEmpty {
                style.bassDepth = min(1.4, style.bassDepth + 0.12)
                // Align bass swap toward first late drop relative to mixOut when possible.
                style.bassSwapAt = max(0.16, style.handoffAt - 0.22)
            }
        }
        if let b {
            let vocalIn = meanHead(b.vocalPresence) ?? meanHead(b.energyCurve) ?? 0.45
            if vocalIn > 0.5 {
                // Strong early vocals on B → keep instrumental pocket longer under A.
                style.vocalPocketDepth = min(1.45, style.vocalPocketDepth + 0.18)
                style.vocalPocketUntil = min(0.94, max(style.vocalPocketUntil, style.handoffAt + 0.3))
                style.incomingVolumeLag = min(0.36, style.incomingVolumeLag + 0.06)
                style.bodyLift = min(1.45, style.bodyLift + 0.18)
            }
            if b.mixInSec > 12 {
                style.incomingVolumeLag = min(0.42, style.incomingVolumeLag + 0.08)
                style.bodyLift = min(1.5, style.bodyLift + 0.12)
            }
            if let drop = b.dropsSec.first(where: { $0 >= 8 && $0 <= 48 }) {
                // Aim handoff so B's early drop lands mid-window.
                style.handoffAt = min(0.62, max(0.38, style.handoffAt))
                _ = drop
            }
        }
    }

    private static func clampRate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 1 }
        return max(0.84, min(1.16, rate))
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
}
