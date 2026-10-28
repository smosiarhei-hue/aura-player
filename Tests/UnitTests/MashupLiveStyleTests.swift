import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Mashup Live Style")
struct MashupLiveStyleTests {
    @Test("Beatmatched plan holds rateB during the window then settles")
    func beatmatchRatesHoldThenSettle() {
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
        let early = style.playbackRates(progress: 0.2)
        #expect(abs(early.incoming - 1.06) < 0.01)
        let late = style.playbackRates(progress: 0.98)
        #expect(abs(late.incoming - 1.0) < 0.05)
        #expect(style.phaseLabel(progress: 0.05).contains("BEATMATCH"))
    }

    @Test("Vocal bed volumes keep A louder while B instrumental sneaks in")
    func vocalInstrumentalVolumes() {
        let style = MashupLiveStyle.resolve(
            plan: nil,
            outgoing: nil,
            incoming: nil,
            outgoingDuration: 210,
            incomingDuration: 200
        )
        let early = style.volumes(progress: 0.12)
        let mid = style.volumes(progress: 0.42)
        let late = style.volumes(progress: 0.92)
        #expect(early.outgoing > early.incoming)
        #expect(early.outgoing > 0.85)
        #expect(mid.outgoing > mid.incoming * 0.7)
        #expect(late.incoming > late.outgoing)
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
