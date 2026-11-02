import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Mashup Live Style")
struct MashupLiveStyleTests {
    @Test("Beatmatched plan accel into rateB, holds, then settles")
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
        #expect(abs(style.rateB - 1.06) < 0.001)

        // Accel from natural tempo — not a hard jump to rateB.
        let start = style.playbackRates(progress: 0)
        #expect(abs(start.incoming - 1.0) < 0.02)
        #expect(abs(start.outgoing - 1.0) < 0.02)

        let midLock = style.playbackRates(progress: 0.35)
        #expect(abs(midLock.incoming - 1.06) < 0.01)

        let late = style.playbackRates(progress: 0.98)
        #expect(abs(late.incoming - 1.0) < 0.05)
        // Apple Automix surfaces a single Mixing badge (no LOCK/KEY sub-phases).
        #expect(style.phaseLabel(progress: 0.05) == "MIXING")
    }

    @Test("Pitch cents ramp in, hold through handoff, ease out")
    func pitchCentsRamp() {
        var style = MashupLiveStyle.fallback
        style.pitchCentsB = 100
        style.handoffAt = 0.50
        style.bassSwapAt = 0.28
        style.isBeatmatched = true
        style.targetBPM = 124
        style.rateB = 1.04

        let early = style.pitchCents(progress: 0.02)
        #expect(abs(early) < 40)
        let locked = style.pitchCents(progress: 0.30)
        #expect(abs(locked - 100) < 1)
        let late = style.pitchCents(progress: 0.95)
        #expect(abs(late) < abs(locked))
        #expect(style.phaseLabel(progress: 0.22) == "MIXING")
    }

    @Test("Apple Automix volumes: A vocal + B beat full, hard mute A at LAND")
    func appleAutomixVolumesHardLand() {
        var style = MashupLiveStyle.resolve(
            plan: nil,
            outgoing: nil,
            incoming: nil,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        style.applyAutomixPlaybackCharacter()
        #expect(style.handoffAt >= 0.88)
        #expect(style.phaseLabel(progress: 0.35) == "MIXING")
        #expect(style.phaseLabel(progress: 0.95) == "MIXING")

        let early = style.volumes(progress: 0.12)
        let mid = style.volumes(progress: 0.50)
        let land = style.volumes(progress: min(0.99, style.handoffAt + 0.01))
        #expect(early.outgoing > 0.95)
        #expect(early.incoming > 0.90) // B beat bed already in
        #expect(mid.outgoing > 0.95)
        #expect(mid.incoming > 0.95)
        #expect(land.outgoing == 0)
        #expect(land.incoming > 0.95)
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
