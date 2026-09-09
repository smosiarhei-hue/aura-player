import MixModels
import MixPlanner
import Testing

@Suite("AutoMix Stage 4 effects")
struct Stage4EffectsTests {
    @Test("Automation curves clamp and reach endpoints")
    func curves() {
        let event = FxEvent(target: .a, kind: .highPass, startBar: 2, endBar: 6,
                            fromValue: 20, toValue: 2_000, curve: .exp)
        #expect(EffectAutomation.value(for: event, atBar: 1) == nil)
        #expect(EffectAutomation.value(for: event, atBar: 2) == 20)
        #expect(abs((EffectAutomation.value(for: event, atBar: 6) ?? 0) - 2_000) < 0.1)
        #expect(abs((EffectAutomation.value(for: event, atBar: 4) ?? 0) - 200) < 1)
    }

    @Test("Musical plan contains all mandatory Stage 4 effects")
    func mandatoryEffects() {
        let plan = MixPlanner.plan(from: profile("a", key: "8A"), to: profile("b", key: "8B"),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        let kinds = Set(plan.fx.map(\.kind))
        #expect(kinds.contains(.highPass)); #expect(kinds.contains(.lowPass))
        #expect(kinds.contains(.bassKill)); #expect(kinds.contains(.bassOn))
        #expect(kinds.contains(.echoOut)); #expect(kinds.contains(.rateRamp))
        #expect(kinds.contains(.volume))
    }

    @Test("Bar and second conversion round trips")
    func timing() {
        let seconds = EffectAutomation.seconds(atBar: 8, bpm: 128)
        #expect(abs(EffectAutomation.bar(atSeconds: seconds, bpm: 128) - 8) < 0.0001)
    }

    private func meta(_ id: String) -> TrackMeta {
        TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: nil, durationSec: 240, artworkURL: nil)
    }
    private func profile(_ id: String, key: String) -> TrackProfile {
        TrackProfile(trackID: TrackID(raw: id), durationSec: 240, sourceSampleRate: 48_000,
                     sourceBitrateKbps: nil, bpm: 124,
                     beatsSec: Array(stride(from: 0.0, to: 240, by: 60.0 / 124.0)),
                     downbeatsSec: Array(stride(from: 0.0, to: 240, by: 240.0 / 124.0)),
                     phraseStartsSec: Array(stride(from: 0.0, to: 240, by: 16)),
                     tempoStability: 1, camelotKey: key, integratedLUFS: -14,
                     loudnessCurveLUFS: [], energyCurve: [], hasFadeOut: false,
                     endsInSilence: false, vocalPresence: [], segments: [],
                     mixInSec: 8, mixOutSec: 220, mixable: true,
                     confidence: Confidence(bpm: 1, downbeats: 1, key: 1))
    }
}
