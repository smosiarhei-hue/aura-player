import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Mashup Live Style")
struct MashupLiveStyleTests {
    @Test("Beatmatched Automix snaps to rateB, holds, then settles")
    func beatmatchRatesAccelHoldSettle() {
        let plan = TransitionPlan(
            type: .beatmatchedShort,
            archetype: .dropSwap,
            aOutStartSec: 160,
            bInStartSec: 16,
            bars: 8,
            tempoTargetBPM: 124,
            rateA: 1.0,
            rateB: 1.06,
            pitchShiftCentsB: 100,
            gainOffsetBdB: 0,
            loopBarsA: 0,
            fx: [],
            reason: "test beatmatch"
        )
        let style = MashupLiveStyle.resolve(
            plan: plan,
            outgoing: nil,
            incoming: nil,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        #expect(style.isBeatmatched)
        #expect(!style.isDuet)
        #expect(abs(style.rateB - 1.06) < 0.001)

        // Apple Automix: locked grid from the first frame (no slow accel from 1.0).
        let start = style.playbackRates(progress: 0)
        #expect(abs(start.incoming - 1.06) < 0.01)
        #expect(abs(start.outgoing - 1.0) < 0.01)

        let midLock = style.playbackRates(progress: 0.35)
        #expect(abs(midLock.incoming - 1.06) < 0.01)

        // Apple Automix LAND remounts dry B at 1.0 — stay locked through the mashup window.
        let late = style.playbackRates(progress: 0.90)
        #expect(abs(late.incoming - 1.06) < 0.01)
        // Apple Automix surfaces a single Mixing badge (no LOCK/KEY sub-phases).
        #expect(style.phaseLabel(progress: 0.05) == "MIXING")
    }

    @Test("Automix pitch snaps in; Duet still ramps")
    func pitchCentsRamp() {
        var style = MashupLiveStyle.fallback
        style.pitchCentsB = 100
        style.handoffAt = 0.50
        style.bassSwapAt = 0.28
        style.isBeatmatched = true
        style.isDuet = false
        style.targetBPM = 124
        style.rateB = 1.04

        let early = style.pitchCents(progress: 0.02)
        #expect(abs(early - 100) < 1)
        let locked = style.pitchCents(progress: 0.30)
        #expect(abs(locked - 100) < 1)
        let late = style.pitchCents(progress: 0.95)
        #expect(abs(late) < abs(locked))
        #expect(style.phaseLabel(progress: 0.22) == "MIXING")

        var duet = style
        duet.isDuet = true
        let duetEarly = duet.pitchCents(progress: 0.02)
        #expect(abs(duetEarly) < 40)
    }

    @Test("Apple Automix volumes: A vocal over quieter B bed, hard mute A at LAND")
    func appleAutomixVolumesHardLand() {
        var style = MashupLiveStyle.resolve(
            plan: nil,
            outgoing: nil,
            incoming: nil,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        style.applyAutomixPlaybackCharacter()
        #expect(style.handoffAt >= 0.78)
        #expect(style.oneVocalConflict)
        #expect(style.phaseLabel(progress: 0.35) == "MIXING")
        #expect(style.phaseLabel(progress: 0.95) == "MIXING")

        let early = style.volumes(progress: 0.12)
        let mid = style.volumes(progress: 0.50)
        let land = style.volumes(progress: min(0.99, style.handoffAt + 0.01))
        #expect(early.outgoing > 0.95)
        #expect(early.incoming > 0.55 && early.incoming < 0.85) // ONE VOCAL bed under A
        #expect(mid.outgoing > 0.95)
        #expect(mid.incoming > 0.55 && mid.incoming < 0.90)
        #expect(land.outgoing == 0)
        #expect(land.incoming > 0.95)
        #expect(abs(style.automixIncomingBedGain - 0.70) < 0.01)
    }

    @Test("Key-clash Automix keeps an even quieter B bed")
    func keyClashBedQuieter() {
        var style = MashupLiveStyle.fallback
        style.applyAutomixPlaybackCharacter()
        style.archetypeName = "echoFreeze"
        style.pitchCentsB = 0
        #expect(style.automixIncomingBedGain < 0.65)
        style.pitchCentsB = -200
        #expect(style.automixIncomingBedGain <= 0.55)
        let mid = style.volumes(progress: 0.4)
        #expect(mid.incoming <= 0.60)
    }

    @Test("Duet plan keeps dual vocal volumes and DUET phase labels")
    func duetVolumesAndPhases() {
        let plan = TransitionPlan(
            type: .beatmatchedShort,
            archetype: .dropSwap,
            aOutStartSec: 150,
            bInStartSec: 8,
            bars: 6,
            tempoTargetBPM: 124,
            rateA: 1.0,
            rateB: 1.03,
            pitchShiftCentsB: 0,
            gainOffsetBdB: 0,
            loopBarsA: 0,
            fx: [],
            reason: "DUET · 6 bars · vocal A + vocal B · instr B · LAND · Точное совпадение ключа (8A)"
        )
        let style = MashupLiveStyle.resolve(
            plan: plan,
            outgoing: nil,
            incoming: nil,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        #expect(style.isDuet)
        #expect(!style.oneVocalConflict)
        #expect(style.handoffAt >= 0.6)
        let mid = style.volumes(progress: 0.4)
        #expect(mid.outgoing > 0.72)
        #expect(mid.incoming > 0.75)
        #expect(style.phaseLabel(progress: 0.05).contains("DUET LOCK"))
        #expect(style.phaseLabel(progress: 0.4).contains("DUET STACK"))
        #expect(style.phaseLabel(progress: 0.7).contains("DUET LAND")
            || style.phaseLabel(progress: 0.7) == "LAND")
    }

    @Test("Profile tempo match produces beatmatch style")
    func profilesBeatmatch() {
        let a = profile("a", bpm: 124, key: "8A", mixIn: 8, mixOut: 168)
        let b = profile("b", bpm: 128, key: "8A", mixIn: 16, mixOut: 160)
        let style = MashupLiveStyle.resolve(
            plan: nil,
            outgoing: a,
            incoming: b,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        #expect(style.isBeatmatched)
        #expect(style.targetBPM > 30)
        #expect(abs(style.rateA - 1) > 0.001 || abs(style.rateB - 1) > 0.001)
    }

    @Test("Different track pairs produce different Automix fingerprints")
    func perPairTransitionFingerprintsDiffer() {
        let compatibleA = profile("song-a", bpm: 124, key: "8A", mixIn: 8, mixOut: 168)
        let compatibleB = profile("song-b", bpm: 126, key: "8A", mixIn: 16, mixOut: 160)
        let clashA = profile("clash-a", bpm: 128, key: "11A", mixIn: 10, mixOut: 170)
        let clashB = profile("clash-b", bpm: 129, key: "5A", mixIn: 4, mixOut: 155)
        let tapeA = profile("tape-a", bpm: 122, key: "8A", mixIn: 8, mixOut: 165)
        let planCompat = TransitionPlan(
            type: .beatmatchedLong, archetype: .seamlessLoop,
            aOutStartSec: 160, bInStartSec: 16, bars: 16, tempoTargetBPM: 125,
            rateA: 1.0, rateB: 1.02, pitchShiftCentsB: 0, gainOffsetBdB: 0, loopBarsA: 0, fx: [],
            reason: "Beatmatch + Camelot (16 тактов, Точное совпадение ключа (8A))"
        )
        let planClash = TransitionPlan(
            type: .filterEcho, archetype: .echoFreeze,
            aOutStartSec: 170, bInStartSec: 4, bars: 6, tempoTargetBPM: 128,
            rateA: 1.0, rateB: 1.0, pitchShiftCentsB: 0, gainOffsetBdB: 0, loopBarsA: 0, fx: [],
            reason: "Echo Out + beatmatch (6 тактов @ 128 BPM, Тональный конфликт)"
        )
        let planTape = TransitionPlan(
            type: .hardCut, archetype: .tapeStop,
            aOutStartSec: 175, bInStartSec: 8, bars: 4, tempoTargetBPM: 122,
            rateA: 1.0, rateB: 1.0, pitchShiftCentsB: 0, gainOffsetBdB: 0, loopBarsA: 0, fx: [],
            reason: "Tape Stop"
        )
        let s1 = MashupLiveStyle.resolve(plan: planCompat, outgoing: compatibleA, incoming: compatibleB, outgoingDuration: 210, incomingDuration: 200)
        let s2 = MashupLiveStyle.resolve(plan: planClash, outgoing: clashA, incoming: clashB, outgoingDuration: 210, incomingDuration: 200)
        let s3 = MashupLiveStyle.resolve(plan: planTape, outgoing: tapeA, incoming: compatibleB, outgoingDuration: 210, incomingDuration: 200)
        #expect(s1.transitionFingerprint != s2.transitionFingerprint)
        #expect(s1.transitionFingerprint != s3.transitionFingerprint)
        #expect(s2.transitionFingerprint != s3.transitionFingerprint)
        #expect(s1.archetypeName != s2.archetypeName || abs(s1.handoffAt - s2.handoffAt) > 0.02)
        #expect(abs(s1.bassSwapAt - s3.bassSwapAt) > 0.05 || s1.archetypeName != s3.archetypeName)
    }

    @Test("Flat plan rates recover beatmatch from profile BPM gap")
    func flatPlanRatesRecoverFromProfiles() {
        let a = profile("a", bpm: 118, key: "11A", mixIn: 8, mixOut: 168)
        let b = profile("b", bpm: 128, key: "11A", mixIn: 16, mixOut: 160)
        let plan = TransitionPlan(
            type: .beatmatchedShort,
            archetype: .dropSwap,
            aOutStartSec: 160,
            bInStartSec: 16,
            bars: 8,
            tempoTargetBPM: 123,
            rateA: 1.0,
            rateB: 1.0,
            pitchShiftCentsB: 0,
            gainOffsetBdB: 0,
            loopBarsA: 0,
            fx: [],
            reason: "Beatmatch + Camelot (8 тактов, Точное совпадение ключа (11A))"
        )
        let style = MashupLiveStyle.resolve(
            plan: plan,
            outgoing: a,
            incoming: b,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        #expect(style.isBeatmatched)
        #expect(abs(style.rateA - 1) > 0.001 || abs(style.rateB - 1) > 0.001)
        let locked = style.playbackRates(progress: 0)
        #expect(abs(locked.outgoing - 1) > 0.001 || abs(locked.incoming - 1) > 0.001)
    }

    private func profile(
        _ id: String,
        bpm: Float,
        key: String,
        mixIn: Double,
        mixOut: Double
    ) -> TrackProfile {
        let duration = 210.0
        return TrackProfile(
            trackID: TrackID(raw: id),
            durationSec: duration,
            sourceSampleRate: 44_100,
            sourceBitrateKbps: 320,
            bpm: bpm,
            beatsSec: Array(stride(from: 0.0, to: duration, by: 0.5)),
            downbeatsSec: Array(stride(from: 0.0, to: duration, by: 2)),
            phraseStartsSec: Array(stride(from: 0.0, to: duration, by: 16)),
            tempoStability: 0.92,
            camelotKey: key,
            integratedLUFS: -14,
            loudnessCurveLUFS: [],
            energyCurve: Array(repeating: 0.6, count: Int(duration)),
            hasFadeOut: false,
            endsInSilence: false,
            vocalPresence: Array(repeating: 0.7, count: Int(duration)),
            segments: [Segment(startSec: 64, endSec: 96, type: .drop)],
            mixInSec: mixIn,
            mixOutSec: mixOut,
            mixable: true,
            confidence: Confidence(bpm: 0.9, downbeats: 0.9, key: 0.9)
        )
    }
}
