// Path: Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift
//
// Per-pair live mashup: real BPM beatmatch with accel/decel into the grid,
// Camelot key ramp, and vocal↔instrumental layering — not a flat crossfade.

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
    /// Locked playback rates during the mashup hold (1.0 = natural tempo).
    public var rateA: Float
    public var rateB: Float
    /// Camelot key compensation on B (cents), ramped in then released.
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

    // MARK: - Beatmatch rates (accel → lock → decel)

    /// Progress where both decks finish accelerating into the locked grid.
    public var tempoLockUntil: Double {
        min(0.28, max(0.10, bassSwapAt * 0.72))
    }

    /// Progress where post-handoff settle (decel to natural tempo) begins.
    public var settleStart: Double {
        max(handoffAt + 0.08, min(0.88, max(0.62, vocalPocketUntil - 0.08)))
    }

    /// Smoothstep 0…1 for DJ-feel accel/decel (no linear jumps).
    public static func smoothstep(_ t: Double) -> Float {
        let x = min(1, max(0, t))
        return Float(x * x * (3 - 2 * x))
    }

    /// Accel from natural tempo into `rateA`/`rateB`, hold the grid, then
    /// decelerate back to 1.0 after the musical handoff (MixPlanner `rateRamp`).
    public func playbackRates(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let lockAt = tempoLockUntil
        let settleAt = settleStart

        let out: Float
        let inn: Float
        if p < lockAt {
            // Accel / decelerate into the shared grid from natural 1.0.
            let t = Self.smoothstep(p / max(0.001, lockAt))
            out = 1 + (rateA - 1) * t
            inn = 1 + (rateB - 1) * t
        } else if p < settleAt {
            inn = rateB
            // Archetype spice: slight outgoing slowdown into handoff (tape feel).
            if (archetypeName == "tapeStop" || archetypeName == "echoFreeze"),
               p > handoffAt - 0.12 {
                let brake = Self.smoothstep((p - (handoffAt - 0.12)) / 0.12)
                out = rateA + (max(0.88, rateA - 0.06) - rateA) * brake
            } else {
                out = rateA
            }
        } else {
            let t = Self.smoothstep((p - settleAt) / max(0.001, 1 - settleAt))
            out = rateA + (1 - rateA) * t
            inn = rateB + (1 - rateB) * t
        }
        return (
            max(0.84, min(1.16, out)),
            max(0.84, min(1.16, inn))
        )
    }

    /// Ramp Camelot pitch in, hold through vocal×instrumental, ease out after handoff.
    public func pitchCents(progress: Double) -> Float {
        guard abs(pitchCentsB) >= 0.5 else { return 0 }
        let p = min(1, max(0, progress))
        let rampInEnd = min(0.22, max(0.08, tempoLockUntil))
        let holdEnd = max(rampInEnd + 0.05, handoffAt)
        if p < rampInEnd {
            return pitchCentsB * Self.smoothstep(p / max(0.001, rampInEnd))
        }
        if p <= holdEnd {
            return pitchCentsB
        }
        let t = Self.smoothstep((p - holdEnd) / max(0.001, 1 - holdEnd))
        return pitchCentsB * (1 - t)
    }

    // MARK: - Volumes (Apple Automix mashup: A instrumental + B vocal×instr together)

    /// Dual-deck mashup levels — both tracks stay audible on the shared grid.
    /// A = outro instrumental layer; B = next track already with vocals + instrumental.
    /// Not a quiet bed under A, and not a simple equal-power crossfade.
    public func volumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let hold = min(0.72, max(0.18, outgoingVolumeHold))
        let lag = min(0.28, max(0.02, incomingVolumeLag * 0.55))
        let handoff = min(0.85, max(hold, handoffAt))
        // B must be loud enough that its vocal + kick read as a real mashup layer.
        let mashupFloor: Float = isBeatmatched ? 0.72 : 0.58
        let mashupPeak: Float = isBeatmatched ? 0.96 : 0.88

        let out: Float
        if p <= hold {
            // A outro instrumental stays present while B locks in on the grid.
            out = 1.0 - Float(p / max(hold, 0.001)) * 0.12
        } else if p <= handoff {
            let t = Self.smoothstep((p - hold) / max(0.001, handoff - hold))
            out = max(0.38, 0.88 * (1 - t * 0.55))
        } else {
            let t = Self.smoothstep((p - handoff) / max(0.001, 1 - handoff))
            out = max(0, 0.38 * (1 - t))
        }

        let inVol: Float
        if p <= lag {
            // Fast rise — next track enters with vocal + instrumental, not a whisper.
            inVol = mashupFloor * Self.smoothstep(p / max(lag, 0.001))
        } else if p <= handoff {
            let t = Self.smoothstep((p - lag) / max(0.001, handoff - lag))
            inVol = mashupFloor + (mashupPeak - mashupFloor) * t
        } else {
            let t = Self.smoothstep((p - handoff) / max(0.001, 1 - handoff))
            inVol = min(1, mashupPeak + (1 - mashupPeak) * t)
        }
        return (out, inVol)
    }

    public func phaseLabel(progress: Double) -> String {
        let p = min(1, max(0, progress))
        if isBeatmatched, p < tempoLockUntil {
            return String(format: "TEMPO LOCK %.0f", targetBPM)
        }
        if abs(pitchCentsB) >= 20, p < min(0.24, max(tempoLockUntil, bassSwapAt * 0.85)) {
            let sign = pitchCentsB >= 0 ? "+" : ""
            return String(format: "KEY SHIFT %@%.0f¢", sign, pitchCentsB)
        }
        if isBeatmatched, p < min(0.30, bassSwapAt) {
            return String(format: "BEATMATCH %.0f", targetBPM)
        }
        if p < bassSwapAt { return "BASS LOCK" }
        if p < vocalHoldUntil { return "MASHUP" }
        if p < handoffAt { return "HANDOFF" }
        if p < vocalPocketUntil { return "VOCAL × INSTR" }
        if p < settleStart { return "SOFT REVEAL" }
        return "TEMPO SETTLE"
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
        // Bass from B locks early; dual-layer mashup fills the window until handoff.
        style.handoffAt = 0.52
        style.bassSwapAt = min(style.handoffAt, max(0.14, style.handoffAt - 0.28))
        style.vocalHoldUntil = min(0.78, style.handoffAt + 0.10)
        style.vocalPocketUntil = min(0.94, style.handoffAt + 0.30)
        style.outgoingVolumeHold = min(0.62, style.handoffAt - 0.04)
        // Short lag so B vocal+instr is in the mashup almost immediately.
        style.incomingVolumeLag = max(0.04, min(0.14, style.bassSwapAt * 0.35))
        refineWithProfiles(&style, a: outgoing, b: incoming)
        if style.isBeatmatched {
            style.reason = "Beatmatch \(Int(round(style.targetBPM))) BPM · bass from B · \(plan.reason)"
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
                bassSwapAt: 0.22,
                vocalHoldUntil: 0.58,
                vocalPocketUntil: 0.84,
                handoffAt: 0.52,
                outgoingVolumeHold: 0.48,
                incomingVolumeLag: 0.06,
                bassDepth: 1.4,
                vocalPocketDepth: 0.55,
                hpfDepth: 1.15,
                bodyLift: 1.35,
                rateA: 1, rateB: 1, pitchCentsB: 0, targetBPM: 0,
                isBeatmatched: false,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .seamlessLoop:
            return MashupLiveStyle(
                bassSwapAt: 0.38,
                vocalHoldUntil: 0.56,
                vocalPocketUntil: 0.88,
                handoffAt: 0.52,
                outgoingVolumeHold: 0.50,
                incomingVolumeLag: 0.18,
                bassDepth: 1.0,
                vocalPocketDepth: 1.15,
                hpfDepth: 0.85,
                bodyLift: 1.35,
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
                incomingVolumeLag: 0.50,
                bassDepth: 1.15,
                vocalPocketDepth: 0.85,
                hpfDepth: 1.35,
                bodyLift: 0.75,
                rateA: 1, rateB: 1, pitchCentsB: 0, targetBPM: 0,
                isBeatmatched: false,
                reason: archetype.rawValue,
                archetypeName: archetype.rawValue
            )
        case .energyWash:
            return MashupLiveStyle(
                bassSwapAt: 0.32,
                vocalHoldUntil: 0.46,
                vocalPocketUntil: 0.78,
                handoffAt: 0.50,
                outgoingVolumeHold: 0.36,
                incomingVolumeLag: 0.10,
                bassDepth: 0.95,
                vocalPocketDepth: 1.05,
                hpfDepth: 1.05,
                bodyLift: 1.1,
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
            if vocalOut < 0.45 {
                // Outro already instrumental — keep A as the bed under B's vocal.
                style.outgoingVolumeHold = min(0.68, style.outgoingVolumeHold + 0.08)
                style.hpfDepth = min(1.4, style.hpfDepth + 0.1)
            } else if vocalOut > 0.55 {
                // Still singing on A → duck A vocal band sooner so B vocal reads clean.
                style.vocalHoldUntil = max(0.32, style.vocalHoldUntil - 0.06)
            }
            if a.hasFadeOut || a.endsInSilence {
                style.hpfDepth *= 0.7
                style.outgoingVolumeHold = max(0.22, style.outgoingVolumeHold - 0.08)
            }
            if !a.dropsSec.isEmpty {
                style.bassDepth = min(1.45, style.bassDepth + 0.15)
                // Hand bass to B early so the next kick owns the groove.
                style.bassSwapAt = max(0.12, style.handoffAt - 0.30)
            }
        }
        if let b {
            let vocalIn = meanHead(b.vocalPresence) ?? meanHead(b.energyCurve) ?? 0.45
            if vocalIn > 0.5 {
                // B already has vocals — keep them in the mashup (do NOT pocket-duck hard).
                style.vocalPocketDepth = max(0.35, style.vocalPocketDepth * 0.45)
                style.incomingVolumeLag = max(0.03, style.incomingVolumeLag * 0.55)
                style.bodyLift = min(1.5, style.bodyLift + 0.20)
            }
            if b.mixInSec > 12 {
                // Enter past padded intro so B is already in vocal+instr territory.
                style.bodyLift = min(1.55, style.bodyLift + 0.12)
            }
            if let drop = b.dropsSec.first(where: { $0 >= 8 && $0 <= 48 }) {
                style.handoffAt = min(0.62, max(0.38, style.handoffAt))
                style.bassSwapAt = min(style.bassSwapAt, max(0.12, style.handoffAt - 0.28))
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
