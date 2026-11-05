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
    /// Both leads present around the cues — never stack two vocals before LAND.
    public var oneVocalConflict: Bool
    /// Lab Modern Duet: intentional dual vocal (A isolate over B full mix).
    public var isDuet: Bool
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
        oneVocalConflict: false,
        isDuet: false,
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
        oneVocalConflict: Bool = false,
        isDuet: Bool = false,
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
        self.oneVocalConflict = oneVocalConflict
        self.isDuet = isDuet
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
    /// Apple Automix (non-duet) snaps to the locked grid immediately — a slow
    /// accel left early MIXING / `bake.ready` at 1.000 even when the plan ≠ 1.
    public func playbackRates(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let settleAt = settleStart

        let out: Float
        let inn: Float
        if !isDuet, isBeatmatched {
            // Snap lock → optional tape/echo brake → settle to natural.
            if p < settleAt {
                inn = rateB
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
        } else {
            let lockAt = tempoLockUntil
            if p < lockAt {
                // Duet / unmatched: accel into the shared grid from natural 1.0.
                let t = Self.smoothstep(p / max(0.001, lockAt))
                out = 1 + (rateA - 1) * t
                inn = 1 + (rateB - 1) * t
            } else if p < settleAt {
                inn = rateB
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
        }
        return (
            max(0.84, min(1.16, out)),
            max(0.84, min(1.16, inn))
        )
    }

    /// Camelot pitch on B. Automix snaps the compensation immediately (short
    /// mashup windows cannot afford a slow key ramp); Duet still ramps in.
    public func pitchCents(progress: Double) -> Float {
        guard abs(pitchCentsB) >= 0.5 else { return 0 }
        let p = min(1, max(0, progress))
        let holdEnd = max(0.15, handoffAt)
        if !isDuet {
            if p <= holdEnd { return pitchCentsB }
            let t = Self.smoothstep((p - holdEnd) / max(0.001, 1 - holdEnd))
            return pitchCentsB * (1 - t)
        }
        let rampInEnd = min(0.22, max(0.08, tempoLockUntil))
        let duetHold = max(rampInEnd + 0.05, handoffAt)
        if p < rampInEnd {
            return pitchCentsB * Self.smoothstep(p / max(0.001, rampInEnd))
        }
        if p <= duetHold {
            return pitchCentsB
        }
        let t = Self.smoothstep((p - duetHold) / max(0.001, 1 - duetHold))
        return pitchCentsB * (1 - t)
    }

    // MARK: - Volumes (Apple Automix: A vocal over B beat → hard LAND)

    /// Apple Automix (IMG_7144): both stems full during the mashup window,
    /// then A hard-cuts at LAND while B stays at unity. Not a crossfade.
    public func volumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        if isDuet { return duetVolumes(progress: progress) }
        return appleAutomixVolumes(progress: progress)
    }

    /// Reference mashup: A vocal over quieter B beat bed → soft A taper → LAND.
    /// Field 1055 held A@1 + B@0.78 for ~12s (muddy stack); LAND waits for B bloom
    /// but dual-loud window must stay short and quiet.
    public var automixLandProgress: Double {
        min(0.92, max(0.84, handoffAt))
    }

    private func appleAutomixVolumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let handoff = automixLandProgress
        let lag = min(0.08, max(0.02, incomingVolumeLag > 0 ? incomingVolumeLag : 0.04))
        // Gentle A body taper mid-window, then soft LAND fade (~14% of blend).
        let bodyTaperStart = 0.38
        let bodyTaperEnd = max(0.58, handoff - 0.18)
        let aHold: Float = 0.82
        let aFadeStart = max(bodyTaperEnd, handoff - 0.14)
        let outgoing: Float
        if p < bodyTaperStart {
            outgoing = 1
        } else if p < bodyTaperEnd {
            let t = Self.smoothstep((p - bodyTaperStart) / max(0.001, bodyTaperEnd - bodyTaperStart))
            outgoing = 1 - (1 - aHold) * t
        } else if p < aFadeStart {
            outgoing = aHold
        } else if p < handoff {
            let t = Self.smoothstep((p - aFadeStart) / max(0.001, handoff - aFadeStart))
            outgoing = aHold * (1 - t)
        } else {
            outgoing = 0
        }
        let bed = automixIncomingBedGain
        // Bloom only in the last ~18% so mid-window stays A-lead × quiet bed.
        let bloomStart = max(lag + 0.06, handoff - 0.18)
        let incoming: Float
        if p <= lag {
            incoming = Self.smoothstep(p / lag) * bed
        } else if p < bloomStart {
            incoming = bed
        } else if p < handoff {
            let t = Self.smoothstep((p - bloomStart) / max(0.001, handoff - bloomStart))
            incoming = bed + (1 - bed) * t
        } else {
            incoming = 1
        }
        return (min(1, max(0, outgoing)), min(1, max(0, incoming)))
    }

    /// Stem AutoMix: the ending instrumental is the bed under the next vocal.
    /// The vocal is already up, so the cut does not leave a hole. The bed
    /// leaves across one bar and the vocal is the dry song.
    public func stemNeuralVolumes(progress: Double, blendSec: Double) -> (outgoing: Float, incoming: Float) {
        if isDuet { return duetVolumes(progress: progress) }
        let p = min(1, max(0, progress))
        let land = automixLandProgress
        let bpm = Double(targetBPM > 30 ? targetBPM : 120)
        let bar = min(0.22, max(0.07, (4 * 60 / bpm) / max(4, blendSec)))
        let release = max(0, land - bar)
        let bed: Float = 0.88
        let outgoing: Float
        if p <= release {
            outgoing = bed
        } else if p < land {
            outgoing = Float(max(0, Double(bed) * (1 - (p - release) / max(0.08, bar))))
        } else {
            outgoing = 0
        }
        let vocal: Float = p >= land ? 1 : min(1, 0.82 + Float(p / 0.12) * 0.18)
        return (outgoing, vocal)
    }

    /// How loud B sits under A during ONE VOCAL Automix (before LAND bloom).
    /// Stems already leak; keep bed clearly under A (field 1055 bed 0.78 was too hot).
    public var automixIncomingBedGain: Float {
        if abs(pitchCentsB) >= 50 { return 0.48 }
        if archetypeName == "echoFreeze" || archetypeName == "spaceReverb" { return 0.52 }
        if oneVocalConflict { return 0.58 }
        return 0.68
    }

    /// Lab `oneBarDuetVolumes`: invite → vocal stack (A stays strong) → LAND A out.
    private func duetVolumes(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let handoff = min(0.72, max(0.52, handoffAt))
        let invite = min(0.14, max(0.05, incomingVolumeLag))
        let aDual = Float(min(0.92, max(0.72, outgoingVolumeHold)))
        let landEnd = 0.94

        let outgoing: Float
        if p <= invite {
            outgoing = 1
        } else if p <= handoff {
            let t = Float((p - invite) / max(0.001, handoff - invite))
            outgoing = 1 - t * (1 - aDual)
        } else if p <= landEnd {
            let landT = Float((p - handoff) / max(0.1, landEnd - handoff))
            outgoing = aDual * (1 - landT)
        } else {
            outgoing = 0
        }

        let incoming: Float
        if p <= invite {
            incoming = Float(p / invite) * 0.78
        } else if p < handoff {
            let t = Float((p - invite) / max(0.001, handoff - invite))
            incoming = 0.78 + 0.22 * t
        } else {
            incoming = 1
        }
        return (min(1, max(0, outgoing)), min(1, max(0, incoming)))
    }

    /// When the user chose Duet, keep dual-vocal grammar even if MixPlanner
    /// could not hard-lock tempo/key (never fall into ONE VOCAL carve).
    public mutating func applyDuetPlaybackCharacter() {
        isDuet = true
        oneVocalConflict = false
        archetypeName = "duet"
        handoffAt = min(0.70, max(0.55, handoffAt > 0 ? handoffAt : 0.66))
        bassSwapAt = max(0.12, min(handoffAt - 0.18, max(0.12, bassSwapAt)))
        vocalHoldUntil = handoffAt
        vocalPocketUntil = min(0.94, handoffAt + 0.16)
        outgoingVolumeHold = max(0.82, outgoingVolumeHold)
        incomingVolumeLag = min(0.12, max(0.05, incomingVolumeLag))
        if !reason.uppercased().contains("DUET") {
            reason = "Duet · \(reason)"
        }
    }

    /// Apple Automix live character: A vocal over quieter B beat, LAND ~final 12–16%.
    /// Preserves per-pair bassSwap / lag. Field 1055 late LAND + hot bed = muddy stack.
    public mutating func applyAutomixPlaybackCharacter() {
        isDuet = false
        oneVocalConflict = true
        if archetypeName == "duet" { archetypeName = "dropSwap" }
        handoffAt = min(0.90, max(0.84, handoffAt > 0.80 ? handoffAt : 0.88))
        // Keep pair-specific bass handoff; only force "early B bass" when unset/extreme.
        if bassSwapAt < 0.015 || bassSwapAt > handoffAt - 0.12 {
            bassSwapAt = min(0.24, max(0.04, handoffAt * 0.20))
        } else {
            bassSwapAt = min(bassSwapAt, max(0.04, handoffAt - 0.40))
        }
        vocalHoldUntil = handoffAt
        vocalPocketUntil = handoffAt
        outgoingVolumeHold = 0.82
        incomingVolumeLag = min(0.10, max(0.02, incomingVolumeLag > 0 ? incomingVolumeLag : 0.03))
        hpfDepth = max(1.0, hpfDepth)
        bassDepth = max(1.05, bassDepth)
        bodyLift = max(0.85, min(1.05, bodyLift))
        if !reason.uppercased().contains("APPLE AUTOMIX") {
            reason = "APPLE AUTOMIX · A vocal × B beat · \(reason)"
        }
    }

    /// Fingerprint of the live Automix envelope — consecutive pairs must differ.
    public var transitionFingerprint: String {
        String(
            format: "%@|h%.2f|b%.2f|lag%.2f|rA%.3f|rB%.3f|p%.0f|bpm%.0f|bed%.2f",
            archetypeName,
            handoffAt,
            bassSwapAt,
            incomingVolumeLag,
            rateA,
            rateB,
            pitchCentsB,
            targetBPM,
            automixIncomingBedGain
        )
    }

    public func phaseLabel(progress: Double) -> String {
        let p = min(1, max(0, progress))
        if isDuet {
            if p < 0.1 {
                if isBeatmatched, targetBPM > 30 {
                    return String(format: "DUET LOCK %.0f", targetBPM)
                }
                return "DUET LOCK"
            }
            if p < handoffAt - 0.05 { return "DUET STACK" }
            if p < handoffAt + 0.08 { return "DUET LAND" }
            return "LAND"
        }
        // User-facing Automix matches the reference: a single Mixing badge.
        return "MIXING"
    }

    // MARK: - Plan / profile

    private static func fromPlan(
        _ plan: TransitionPlan,
        outgoing: TrackProfile?,
        incoming: TrackProfile?
    ) -> MashupLiveStyle {
        let isDuetPlan = plan.reason.hasPrefix("DUET ·")
        var style = base(for: plan.archetype)
        style.reason = plan.reason
        style.archetypeName = isDuetPlan ? "duet" : plan.archetype.rawValue
        style.isDuet = isDuetPlan
        let matched = abs(plan.rateA - 1) > 0.002 || abs(plan.rateB - 1) > 0.002 || plan.tempoTargetBPM > 30
        style.isBeatmatched = matched && plan.type != .crossfade && plan.type != .none
        style.rateA = clampRate(plan.rateA)
        style.rateB = clampRate(plan.rateB)
        // Duet may push ±300¢; Automix caps ±100¢ — TimePitch at ±200 sounded cheap (1055).
        style.pitchCentsB = isDuetPlan
            ? max(-300, min(300, plan.pitchShiftCentsB))
            : max(-100, min(100, plan.pitchShiftCentsB))
        style.targetBPM = plan.tempoTargetBPM > 30 ? plan.tempoTargetBPM : 0
        // Field 1047: some beatmatch plans arrived with rateA=rateB=1.000 while
        // profiles still disagree on BPM — rebuild the grid from profiles.
        if abs(style.rateA - 1) < 0.002, abs(style.rateB - 1) < 0.002,
           let a = outgoing, let b = incoming,
           a.bpm > 30, b.bpm > 30,
           abs(a.bpm - b.bpm) / max(a.bpm, 1) > 0.015,
           let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm) {
            style.rateA = clampRate(tempo.rateA)
            style.rateB = clampRate(tempo.rateB)
            style.targetBPM = tempo.targetBPM
            style.isBeatmatched = true
        }
        if isDuetPlan {
            style.handoffAt = 0.68
            style.bassSwapAt = max(0.14, style.handoffAt - 0.22)
            style.vocalHoldUntil = style.handoffAt
            style.vocalPocketUntil = min(0.94, style.handoffAt + 0.18)
            style.outgoingVolumeHold = abs(plan.pitchShiftCentsB) >= 80 ? 0.78 : 0.86
            style.incomingVolumeLag = min(0.16, max(0.07, 0.85 / max(4, plan.bars)))
            style.oneVocalConflict = false
            style.hpfDepth = 1.15
            style.bassDepth = 1.05
            style.bodyLift = 1.1
            if style.isBeatmatched {
                style.reason = "Duet beatmatch \(Int(round(style.targetBPM))) BPM · \(plan.reason)"
            }
            return style
        }
        // Per-pair Automix envelope from archetype + plan length (not one 0.92/0.02 clone).
        applyPairAutomixEnvelope(&style, plan: plan, outgoing: outgoing, incoming: incoming)
        refineWithProfiles(&style, a: outgoing, b: incoming)
        style.applyAutomixPlaybackCharacter()
        if style.isBeatmatched {
            style.reason = "Beatmatch \(Int(round(style.targetBPM))) BPM · \(style.archetypeName) · \(plan.reason)"
        }
        return style
    }

    /// Derive distinct handoff / bass / lag from this pair's plan + profiles.
    private static func applyPairAutomixEnvelope(
        _ style: inout MashupLiveStyle,
        plan: TransitionPlan,
        outgoing: TrackProfile?,
        incoming: TrackProfile?
    ) {
        let barFactor = min(1.0, max(0.0, (plan.bars - 4.0) / 20.0))
        let conflict: Bool = {
            guard let a = outgoing, let b = incoming else { return true }
            let vocalOut = meanTail(a.vocalPresence) ?? meanTail(a.energyCurve) ?? 0.5
            let vocalIn = meanHead(b.vocalPresence) ?? meanHead(b.energyCurve) ?? 0.45
            return vocalOut >= 0.42 && vocalIn >= 0.4
        }()
        style.oneVocalConflict = conflict
        style.outgoingVolumeHold = 0.82
        switch plan.archetype {
        case .echoFreeze, .spaceReverb:
            style.handoffAt = 0.84 + 0.04 * barFactor
            style.bassSwapAt = 0.10 + 0.14 * (1 - barFactor)
            style.incomingVolumeLag = conflict ? 0.05 : 0.08
        case .seamlessLoop:
            style.handoffAt = 0.86 + 0.04 * barFactor
            style.bassSwapAt = 0.12 + 0.16 * barFactor
            style.incomingVolumeLag = 0.06 + 0.04 * barFactor
        case .tapeStop:
            style.handoffAt = 0.90
            style.bassSwapAt = 0.45
            style.incomingVolumeLag = 0.04
        case .beatStutter:
            style.handoffAt = 0.86 + 0.04 * barFactor
            style.bassSwapAt = 0.04
            style.incomingVolumeLag = 0.03
        case .energyWash:
            style.handoffAt = 0.84 + 0.04 * barFactor
            style.bassSwapAt = 0.18 + 0.08 * (1 - barFactor)
            style.incomingVolumeLag = 0.07
        case .dropSwap:
            style.handoffAt = 0.86 + 0.04 * barFactor
            style.bassSwapAt = 0.03 + 0.10 * (1 - barFactor)
            style.incomingVolumeLag = conflict ? 0.03 : 0.05
        }
        style.vocalHoldUntil = style.handoffAt
        style.vocalPocketUntil = style.handoffAt
        // Light salt from track ids so near-identical analysis still diverges slightly.
        if let a = outgoing, let b = incoming {
            let salt = pairSalt(a.trackID.raw, b.trackID.raw)
            // Keep salt inside clean LAND band (0.84…0.90) — not the old 0.92+ mud window.
            style.handoffAt = min(0.90, max(0.84, style.handoffAt + salt * 0.02))
            style.bassSwapAt = min(style.handoffAt - 0.15, max(0.02, style.bassSwapAt + salt * 0.04))
            style.incomingVolumeLag = min(0.10, max(0.02, style.incomingVolumeLag + abs(salt) * 0.02))
        }
    }

    /// Stable −1…+1 spice from pair ids (not random — same pair → same mix).
    private static func pairSalt(_ aID: String, _ bID: String) -> Double {
        var hash: UInt64 = 5381
        for byte in (aID + "→" + bID).utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let unit = Double(hash % 1001) / 1000.0 // 0…1
        return unit * 2 - 1
    }

    private static func fromProfiles(a: TrackProfile, b: TrackProfile) -> MashupLiveStyle {
        let bpmDiff: Float = (a.bpm > 30 && b.bpm > 30) ? abs(a.bpm - b.bpm) / max(a.bpm, 1) : 1
        let harmonic = CamelotCompatibility.match(a.camelotKey, b.camelotKey)
        let tempo = BeatGridSynchronization.tempoMatch(aBPM: a.bpm, bBPM: b.bpm)
        let bpmClose = bpmDiff <= 0.08
        let bpmFar = bpmDiff > 0.08
        let bpmVeryFar = bpmDiff > 0.12

        let energyOut = meanTail(a.energyCurve) ?? 0.5
        let energyIn = meanHead(b.energyCurve) ?? 0.45
        let energyJump = energyIn - energyOut
        let hasIncomingDrop = b.dropsSec.contains { $0 >= 6 && $0 <= 48 }

        // TZ §2.4 — same ladder as Automix Lab / MixPlanner (per-pair spice).
        let archetype: MixTransitionArchetype
        if tempo == nil && bpmVeryFar {
            archetype = .echoFreeze
        } else if (bpmFar && !harmonic.isHarmonicallyViable) || (bpmVeryFar && !harmonic.isNaturallyCompatible) {
            archetype = .echoFreeze
        } else if a.tempoStability >= 0.85, b.tempoStability >= 0.85, harmonic.isNaturallyCompatible, bpmClose {
            archetype = .seamlessLoop
        } else if harmonic.isNaturallyCompatible && bpmClose && energyJump >= 0.22 && hasIncomingDrop {
            archetype = .beatStutter
        } else if harmonic.isNaturallyCompatible && bpmClose && energyOut >= 0.65 && energyJump <= -0.18 {
            archetype = .tapeStop
        } else if harmonic.isNaturallyCompatible && bpmClose {
            archetype = .dropSwap
        } else if harmonic.isHarmonicallyViable && bpmDiff <= 0.1 {
            archetype = energyJump >= 0.18 && hasIncomingDrop ? .beatStutter : .dropSwap
        } else if bpmClose && !harmonic.isNaturallyCompatible {
            // Key clash but tempos lock → Echo Out, keep beatmatch below.
            archetype = .echoFreeze
        } else if a.dropsSec.isEmpty && b.dropsSec.isEmpty {
            archetype = .energyWash
        } else {
            archetype = tempo == nil ? .energyWash : .dropSwap
        }

        var style = base(for: archetype)
        style.archetypeName = archetype.rawValue
        if let tempo {
            style.isBeatmatched = true
            style.rateA = clampRate(tempo.rateA)
            style.rateB = clampRate(tempo.rateB)
            style.targetBPM = tempo.targetBPM
            style.pitchCentsB = harmonic.isHarmonicallyViable
                ? max(-100, min(100, harmonic.pitchShiftCents))
                : 0
            style.reason = String(
                format: "Beatmatch %.0f BPM · %@ · %d→%d · %@",
                tempo.targetBPM, archetype.rawValue, Int(a.bpm), Int(b.bpm), harmonic.description
            )
        } else {
            style.isBeatmatched = false
            style.reason = "No safe tempo match · \(archetype.rawValue)"
        }
        refineWithProfiles(&style, a: a, b: b)
        style.applyAutomixPlaybackCharacter()
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
        let vocalOut = a.map { meanTail($0.vocalPresence) ?? meanTail($0.energyCurve) ?? 0.5 } ?? 0.5
        let vocalIn = b.map { meanHead($0.vocalPresence) ?? meanHead($0.energyCurve) ?? 0.45 } ?? 0.45
        let conflict = vocalOut >= 0.42 && vocalIn >= 0.4

        if style.isDuet {
            // Intentional dual lead — never apply ONE VOCAL carve.
            style.oneVocalConflict = false
            return
        }

        if conflict {
            // Apple Automix: A keeps the lead vocal; B is the beat bed until LAND.
            style.oneVocalConflict = true
            style.vocalHoldUntil = style.handoffAt
            style.vocalPocketUntil = style.handoffAt
            style.vocalPocketDepth = max(1.0, style.vocalPocketDepth)
            style.hpfDepth = min(1.15, style.hpfDepth + 0.05)
            style.incomingVolumeLag = min(0.04, style.incomingVolumeLag)
            style.bodyLift = min(1.2, style.bodyLift)
            if !style.reason.contains("APPLE AUTOMIX") {
                style.reason += " · APPLE AUTOMIX"
            }
        } else if vocalOut < 0.45 {
            // Outro already instrumental — invite B vocal early (ideal mashup).
            style.oneVocalConflict = false
            style.outgoingVolumeHold = min(0.68, style.outgoingVolumeHold + 0.08)
            style.hpfDepth = min(1.4, style.hpfDepth + 0.1)
            style.incomingVolumeLag = max(0.06, style.incomingVolumeLag * 0.7)
            style.vocalPocketDepth = max(0.35, style.vocalPocketDepth * 0.55)
            style.vocalPocketUntil = min(style.vocalPocketUntil, max(0.35, style.bassSwapAt + 0.1))
        } else if vocalOut >= 0.42 && vocalIn < 0.4 {
            // A still sings over an instrumental B bed — soft A carve, no B vocalize.
            style.oneVocalConflict = false
            style.vocalHoldUntil = max(0.32, style.vocalHoldUntil - 0.04)
            style.vocalPocketDepth = max(0.8, style.vocalPocketDepth)
        }

        if let a {
            if a.hasFadeOut || a.endsInSilence {
                style.hpfDepth *= 0.7
                style.outgoingVolumeHold = max(0.22, style.outgoingVolumeHold - 0.08)
            }
            if !a.dropsSec.isEmpty {
                style.bassDepth = min(1.45, style.bassDepth + 0.15)
                style.bassSwapAt = max(0.12, style.handoffAt - 0.30)
            }
        }
        if let b {
            if !conflict, vocalIn > 0.5, vocalOut < 0.45 {
                style.bodyLift = min(1.5, style.bodyLift + 0.20)
            }
            if b.mixInSec > 12 {
                style.bodyLift = min(1.55, style.bodyLift + 0.12)
            }
            if let drop = b.dropsSec.first(where: { $0 >= 8 && $0 <= 48 }) {
                style.handoffAt = min(0.62, max(0.38, style.handoffAt))
                style.bassSwapAt = min(style.bassSwapAt, max(0.12, style.handoffAt - 0.28))
                if style.oneVocalConflict {
                    style.vocalPocketUntil = max(style.handoffAt + 0.06, style.vocalPocketUntil)
                }
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
