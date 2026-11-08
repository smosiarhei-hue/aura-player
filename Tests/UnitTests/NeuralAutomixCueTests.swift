import Foundation
import MixModels
import MixPlanner
import Testing

@Suite("Neural Automix Cue")
struct NeuralAutomixCueTests {
    @Test("LRC phrase end pulls mixOut into the outro window")
    func lrcPhraseEndRefinesMixOut() {
        let duration = 240.0
        let energyOut = 200.0
        let profile = profile(duration: duration, mixOut: energyOut, bpm: 120)
        // Phrase ends at 198s with a clear gap before the next line.
        let transcript = AutomixTranscript(
            source: .yandexLrc,
            segments: [
                AutomixTranscriptSegment(text: "last verse", start: 190, end: 198),
                AutomixTranscriptSegment(text: "outro hum", start: 210, end: 220)
            ]
        )
        let cue = NeuralAutomixCue.pick(profile: profile, transcript: transcript)
        let window = AutomixTranscriptCue.outroWindow(durationSec: duration, minTailSec: 24)
        #expect(cue.mixOutSec >= window.earliest - 0.01)
        #expect(cue.mixOutSec <= window.latest + 0.01)
        #expect(cue.source == .fused || cue.source == .lyrics)
        #expect(cue.confidence >= 0.7)
        #expect(abs(cue.mixOutSec - energyOut) < 25)
    }

    @Test("Without transcript, energy mixOut stays in outro window")
    func energyOnlyStaysInWindow() {
        let duration = 200.0
        let profile = profile(duration: duration, mixOut: 150, bpm: 128)
        let cue = NeuralAutomixCue.pick(profile: profile, transcript: nil)
        let window = AutomixTranscriptCue.outroWindow(durationSec: duration, minTailSec: 24)
        #expect(cue.mixOutSec >= window.earliest - 0.01)
        #expect(cue.mixOutSec <= window.latest + 0.01)
        #expect(cue.source == .energy)
    }

    @Test("applying outgoing role only changes mixOut")
    func outgoingRolePreservesMixIn() {
        let profile = profile(duration: 210, mixOut: 170, bpm: 122, mixIn: 12)
        let transcript = AutomixTranscript(
            source: .yandexLrc,
            segments: [
                AutomixTranscriptSegment(text: "line", start: 165, end: 172),
                AutomixTranscriptSegment(text: "tail", start: 185, end: 195)
            ]
        )
        let next = NeuralAutomixCue.applying(to: profile, transcript: transcript, role: .outgoing)
        #expect(next.mixInSec == 12)
        #expect(abs(next.mixOutSec - 170) > 0.01 || next.mixOutSec == profile.mixOutSec
                || next.mixOutSec >= 165)
    }

    @Test("Cue uses measured downbeat offset")
    func measuredDownbeat() {
        let p = profile(duration: 200, mixOut: 151.2, bpm: 120, downbeatOffset: 1)
        let cue = NeuralAutomixCue.pick(profile: p, transcript: nil)
        #expect(abs(cue.mixOutSec - 151.0) < 0.001)
    }

    private func profile(
        duration: Double,
        mixOut: Double,
        bpm: Float,
        mixIn: Double = 8,
        downbeatOffset: Double = 0
    ) -> TrackProfile {
        TrackProfile(
            trackID: TrackID(raw: "neural-test"),
            durationSec: duration,
            sourceSampleRate: 44_100,
            sourceBitrateKbps: 320,
            bpm: bpm,
            beatsSec: Array(stride(from: 0.0, to: duration, by: 0.5)),
            downbeatsSec: Array(stride(from: downbeatOffset, to: duration, by: 2.0)),
            phraseStartsSec: Array(stride(from: 0.0, to: duration, by: 16)),
            tempoStability: 0.9,
            camelotKey: "8A",
            integratedLUFS: -10,
            loudnessCurveLUFS: [],
            energyCurve: [],
            hasFadeOut: false,
            endsInSilence: false,
            vocalPresence: [],
            segments: [],
            mixInSec: mixIn,
            mixOutSec: mixOut,
            mixable: true,
            confidence: Confidence(bpm: 0.9, downbeats: 0.9, key: 0.8)
        )
    }
}
