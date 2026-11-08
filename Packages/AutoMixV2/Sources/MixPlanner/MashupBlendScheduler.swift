// Path: Packages/AutoMixV2/Sources/MixPlanner/MashupBlendScheduler.swift
//
// Chooses mashup blend points from track structure (mixOut / mixIn), not a
// fixed "N seconds before the end" window. Mirrors Apple Music AutoMix intent:
// start the handoff in the outro, enter the next track on a musical intro cue,
// and let blend length follow the available outro / bar ladder — never a UI slider.

import Foundation
import MixModels

public struct LiveMashupBlend: Sendable, Equatable {
    public let outgoingCueSec: Double
    public let blendDurationSec: Double
    public let incomingStartSec: Double
    public let reason: String

    public init(
        outgoingCueSec: Double,
        blendDurationSec: Double,
        incomingStartSec: Double,
        reason: String,
        landProgress: Double = 0.86
    ) {
        self.outgoingCueSec = outgoingCueSec
        self.blendDurationSec = blendDurationSec
        self.incomingStartSec = incomingStartSec
        self.reason = reason
        self.landProgress = min(0.93, max(0.58, landProgress))
    }

    /// Where the dry incoming track takes over (0…1 of the blend).
    public let landProgress: Double
}

public enum MashupBlendScheduler {
    /// Absolute floors / ceilings for live PlayerCore mashup windows.
    public static let minimumBlendSec: Double = 4
    public static let maximumBlendSec: Double = 32
    /// Live Automix stem window floor (~4 bars @ 120). Full length follows
    /// outro/bar ladder up to PlayerCore's Automix ceiling. Not a UI slider.
    public static let defaultPreferredBlendSec: Double = 8
    /// Never cut the outgoing body before this fraction of the track (Apple-style: play the song).
    public static let minimumPlayedFraction: Double = 0.75
    /// Leave at least this much tail after the cue so the outro can finish under the blend.
    public static let minimumTailSec: Double = 6

    /// Build a live mashup schedule for PlayerCore.
    /// Prefers analysed `TrackProfile` cues when present; otherwise uses structural heuristics.
    /// `preferredBlendSec` is only a short-track / cold-start floor — blend length follows
    /// detected outro / intro (and bar ladders), not a settings slider.
    public static func schedule(
        outgoingDuration: Double,
        incomingDuration: Double,
        preferredBlendSec: Double = defaultPreferredBlendSec,
        outgoing: TrackProfile? = nil,
        incoming: TrackProfile? = nil
    ) -> LiveMashupBlend {
        let outDur = max(0, outgoingDuration)
        let inDur = max(0, incomingDuration)
        let preferred = clamp(preferredBlendSec, min: minimumBlendSec, max: maximumBlendSec)

        if let a = outgoing, let b = incoming, a.mixable, b.mixable, a.durationSec > 45, b.durationSec > 45 {
            return scheduleFromProfiles(a: a, b: b)
        }
        if let a = outgoing, a.durationSec > 20 {
            return scheduleFromOutgoingProfile(a: a, incomingDuration: inDur, incoming: incoming)
        }
        return scheduleHeuristic(
            outgoingDuration: outDur,
            incomingDuration: inDur,
            preferred: preferred,
            incomingMixIn: incoming.map { max(0, $0.mixInSec) }
        )
    }

    /// Pure structural estimate without PCM analysis (streaming / cold start).
    public static func heuristicCues(
        duration: Double,
        bpm: Double = 120,
        role: CueRole
    ) -> Double {
        let dur = max(0, duration)
        let barSec = max(0.4, 240.0 / max(60, bpm)) // 4 beats
        switch role {
        case .mixOut:
            let outroBars = dur > 140 ? 16.0 : 8.0
            let phraseOut = dur - barSec * outroBars
            let floor = dur * minimumPlayedFraction
            let ceiling = max(floor, dur - minimumTailSec)
            return clamp(max(floor, phraseOut), min: floor, max: ceiling)
        case .mixIn:
            // Soft intro lead: skip a short padded intro on longer tracks.
            guard dur >= 90 else { return 0 }
            let leadBars = dur > 180 ? 8.0 : 4.0
            return clamp(barSec * leadBars, min: 0, max: min(32, dur * 0.25))
        }
    }

    public enum CueRole: Sendable {
        case mixIn
        case mixOut
    }

    /// Re-anchor A when the live Automix blend is shorter than the planned outro window.
    public static func reanchorOutgoingCue(
        preferredCue: Double,
        totalDur: Double,
        blend: Double
    ) -> Double {
        let floor = totalDur * minimumPlayedFraction
        let ceiling = max(floor, totalDur - minimumBlendSec)
        let tailAligned = max(0, totalDur - max(minimumBlendSec, blend))
        let cue = abs(preferredCue - tailAligned) <= 2.5 ? preferredCue : tailAligned
        return min(max(cue, floor), ceiling)
    }

    /// Cap B entry to the intro so LAND does not jump mid-body.
    /// Floor keeps Automix off cold opens (field 1151 mood.pick inCue=0.1).
    public static let minimumIncomingCueSec: Double = 4.0

    public static func clampAutomixIncomingCue(
        preferred: Double,
        incomingDur: Double
    ) -> Double {
        guard incomingDur > 30 else { return max(0, preferred) }
        let introCap = min(18.0, max(8.0, incomingDur * 0.18))
        let floored = max(minimumIncomingCueSec, preferred)
        return min(floored, introCap)
    }

    /// After mood retargeting, recover a nearby detected downbeat on both
    /// tracks without exceeding the intro, outro or remaining-audio bounds.
    /// Returns nil instead of inventing a grid or moving either cue too far.
    public static func retargetToDownbeats(
        outgoingCue: Double, incomingCue: Double,
        outgoingDuration: Double, incomingDuration: Double,
        blend: Double, outgoingRate: Double, notBefore: Double,
        outgoingBPM: Double, incomingBPM: Double,
        outgoingDownbeats: [Double], incomingDownbeats: [Double]
    ) -> (outgoing: Double, incoming: Double)? {
        let values = [outgoingCue, incomingCue, outgoingDuration, incomingDuration,
                      blend, outgoingRate, notBefore, outgoingBPM, incomingBPM]
        guard values.allSatisfy({ $0.isFinite }),
              outgoingDuration > 45, incomingDuration > 45,
              blend >= minimumBlendSec, outgoingRate >= 0.9199, outgoingRate <= 1.0801,
              outgoingBPM > 30, incomingBPM > 30 else { return nil }
        let outMin = max(outgoingDuration * minimumPlayedFraction, notBefore)
        // Reserve the whole planned overlap at the faster of natural/locked A.
        let outMax = outgoingDuration - blend * max(1, outgoingRate)
        let inMin = minimumIncomingCueSec
        // Never push B forward into a possible vocal onset merely to hit grid.
        let inMax = min(incomingCue + 0.02, min(18, max(8, incomingDuration * 0.18)))
        guard outMin <= outMax, inMin <= inMax else { return nil }
        func nearby(_ beats: [Double], cue: Double, lower: Double, upper: Double, bpm: Double) -> Double? {
            let maxShift = min(0.75, 60 / bpm)
            return beats.filter { $0.isFinite && $0 >= lower && $0 <= upper && abs($0 - cue) <= maxShift }
                .min { abs($0 - cue) < abs($1 - cue) }
        }
        guard let a = nearby(outgoingDownbeats, cue: outgoingCue, lower: outMin, upper: outMax, bpm: outgoingBPM),
              let b = nearby(incomingDownbeats, cue: incomingCue, lower: inMin, upper: inMax, bpm: incomingBPM) else { return nil }
        return (a, b)
    }

    // MARK: - Profile-backed

    private static func scheduleFromProfiles(a: TrackProfile, b: TrackProfile) -> LiveMashupBlend {
        let bpm = Double(a.bpm > 30 ? a.bpm : (b.bpm > 30 ? b.bpm : 120))
        let barSec = 240.0 / max(60, bpm)
        let availableOutro = max(minimumBlendSec, a.durationSec - a.mixOutSec)
        // Prefer an 8–16 bar window when the outro has room; otherwise shrink to available.
        let ladder = availableOutro >= barSec * 14 ? barSec * 16 : (availableOutro >= barSec * 7 ? barSec * 8 : availableOutro)
        let blend = clamp(min(ladder, availableOutro), min: minimumBlendSec, max: maximumBlendSec)

        let rawOut = BeatGridSynchronization.outgoingCue(profile: a, duration: blend)
        // Snap both cues to downbeats so B's kick lands in phase with A's grid.
        let snappedOut = a.downbeatsSec.min(by: { abs($0 - rawOut) < abs($1 - rawOut) }) ?? rawOut
        let outCue = clamp(
            snappedOut,
            min: a.durationSec * minimumPlayedFraction,
            max: max(a.durationSec * minimumPlayedFraction, a.durationSec - minimumBlendSec)
        )
        // Blend length follows the remaining outro tail (musical ladder already applied).
        let naturalBlend = max(minimumBlendSec, a.durationSec - outCue)
        let finalBlend = clamp(min(naturalBlend, max(blend, minimumBlendSec)), min: minimumBlendSec, max: maximumBlendSec)

        let rawIn = BeatGridSynchronization.incomingCue(profile: b, duration: finalBlend)
        let snappedIn = b.downbeatsSec.min(by: { abs($0 - rawIn) < abs($1 - rawIn) }) ?? rawIn
        let clampedIn = clamp(snappedIn, min: 0, max: max(0, b.durationSec - finalBlend - 1))

        return LiveMashupBlend(
            outgoingCueSec: outCue,
            blendDurationSec: finalBlend,
            incomingStartSec: clampedIn,
            reason: "Profile mashup on grid · A@\(fmt(outCue)) → B@\(fmt(clampedIn)) · \(fmt(finalBlend))"
        )
    }

    private static func scheduleFromOutgoingProfile(
        a: TrackProfile,
        incomingDuration: Double,
        incoming: TrackProfile?
    ) -> LiveMashupBlend {
        let floor = a.durationSec * minimumPlayedFraction
        let mixOut = clamp(a.mixOutSec, min: floor, max: max(floor, a.durationSec - minimumTailSec))
        let natural = max(minimumBlendSec, a.durationSec - mixOut)
        let blend = clamp(natural, min: minimumBlendSec, max: min(maximumBlendSec, natural))
        let inStart: Double
        if let b = incoming {
            inStart = clamp(b.mixInSec, min: 0, max: max(0, b.durationSec * 0.25))
        } else {
            inStart = heuristicCues(duration: incomingDuration, role: .mixIn)
        }
        return LiveMashupBlend(
            outgoingCueSec: mixOut,
            blendDurationSec: blend,
            incomingStartSec: inStart,
            reason: "Outgoing profile mixOut \(fmt(mixOut))"
        )
    }

    private static func scheduleHeuristic(
        outgoingDuration: Double,
        incomingDuration: Double,
        preferred: Double,
        incomingMixIn: Double?
    ) -> LiveMashupBlend {
        guard outgoingDuration > 20 else {
            let blend = clamp(
                preferred,
                min: minimumBlendSec,
                max: min(maximumBlendSec, max(minimumBlendSec, outgoingDuration * 0.2))
            )
            return LiveMashupBlend(
                outgoingCueSec: max(0, outgoingDuration - blend),
                blendDurationSec: blend,
                incomingStartSec: incomingMixIn ?? 0,
                reason: "Short-track fallback"
            )
        }

        // Detected outro cue first; blend length is the remaining tail (not a slider).
        let mixOut = heuristicCues(duration: outgoingDuration, role: .mixOut)
        let floor = outgoingDuration * minimumPlayedFraction
        let finalCue = clamp(mixOut, min: floor, max: max(floor, outgoingDuration - minimumBlendSec))
        let natural = max(minimumBlendSec, outgoingDuration - finalCue)
        let blend = clamp(natural, min: minimumBlendSec, max: min(maximumBlendSec, natural))
        let inStart = incomingMixIn ?? heuristicCues(duration: incomingDuration, role: .mixIn)

        return LiveMashupBlend(
            outgoingCueSec: finalCue,
            blendDurationSec: blend,
            incomingStartSec: max(0, inStart),
            reason: "Heuristic outro \(fmt(finalCue)) / intro \(fmt(inStart))"
        )
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        let hi = max(lower, upper)
        return Swift.min(hi, Swift.max(lower, value))
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1fs", value)
    }
}
