import MixModels
import MixPlanner
import Testing
import TrackAnalysis

@Suite("AutoMix Stage 3")
struct Stage3BeatMatchTests {
    @Test("Tempo pairs are safely matched", arguments: [(120.0,128.0),(128.0,120.0),(90.0,174.0)])
    func tempoPairs(pair: (Double, Double)) {
        let match = BeatGridSynchronization.tempoMatch(aBPM: Float(pair.0), bBPM: Float(pair.1))
        #expect(match != nil)
        #expect(match?.rateA == 1.0)
        #expect(match?.targetBPM == Float(pair.0))
        #expect(abs((match?.rateB ?? 0) - 1) <= 0.08)
    }

    @Test("Unsafe tempo falls back")
    func unsafeTempo() {
        #expect(BeatGridSynchronization.tempoMatch(aBPM: 100, bBPM: 135) == nil)
    }

    @Test("Camelot wheel compatibility")
    func camelot() {
        #expect(CamelotCompatibility.areCompatible("8A", "8B"))
        #expect(CamelotCompatibility.areCompatible("8A", "9A"))
        #expect(CamelotCompatibility.areCompatible("1A", "12A"))
        #expect(!CamelotCompatibility.areCompatible("8A", "2B"))
    }

    @Test("Reliable pair selects beatmatched transition")
    func beatmatchedPlan() {
        let plan = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A"),
                                   to: profile("b", bpm: 128, key: "8B"),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(plan.type == .beatmatchedLong)
        #expect(plan.bars == 16)
        #expect(plan.rateA == 1.0)
        #expect(plan.rateB != 1.0)
    }

    @Test("Confidence ladder selects expected duration and type")
    func confidenceLadder() {
        let high = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A", confidence: 0.9, stability: 0.95),
                                   to: profile("b", bpm: 128, key: "8B", confidence: 0.9, stability: 0.95),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(high.type == .beatmatchedLong); #expect(high.bars == 16)

        let medium = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A", confidence: 0.75, stability: 0.88),
                                     to: profile("b", bpm: 128, key: "8B", confidence: 0.75, stability: 0.88),
                                     aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(medium.type == .beatmatchedShort); #expect(medium.bars == 8)

        let low = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A", confidence: 0.60, stability: 0.78),
                                  to: profile("b", bpm: 128, key: "8B", confidence: 0.60, stability: 0.78),
                                  aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(low.type == .beatmatchedShort); #expect(low.bars == 4)
    }

    @Test("Phase error greater than 80ms falls back to crossfade")
    func phaseErrorFallback() {
        var b = profile("b", bpm: 128, key: "8B")
        b = TrackProfile(trackID: b.trackID, durationSec: b.durationSec,
                         sourceSampleRate: b.sourceSampleRate, sourceBitrateKbps: b.sourceBitrateKbps,
                         bpm: b.bpm, beatsSec: b.beatsSec,
                         downbeatsSec: Array(stride(from: 0.09, to: 240, by: 2)),
                         phraseStartsSec: [], tempoStability: 1, camelotKey: b.camelotKey,
                         integratedLUFS: b.integratedLUFS, loudnessCurveLUFS: [], energyCurve: [],
                         hasFadeOut: false, endsInSilence: false, vocalPresence: [], segments: [],
                         mixInSec: 0, mixOutSec: b.mixOutSec, mixable: true,
                         confidence: b.confidence)
        let plan = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A"), to: b,
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(plan.type == .crossfade)
        #expect(plan.reason.contains("80ms"))
    }

    @Test("Low confidence uses crossfade")
    func fallback() {
        let plan = MixPlanner.plan(from: profile("a", bpm: 120, confidence: 0.4),
                                   to: profile("b", bpm: 128),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(plan.type == .crossfade)
        #expect(plan.reason.contains("Fallback"))
    }

    private func meta(_ id: String) -> TrackMeta {
        TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: nil, durationSec: 240, artworkURL: nil)
    }
    private func profile(_ id: String, bpm: Float, key: String? = nil, confidence: Float = 1, stability: Float = 1) -> TrackProfile {
        TrackProfile(trackID: TrackID(raw: id), durationSec: 240, sourceSampleRate: 48_000,
                     sourceBitrateKbps: nil, bpm: bpm,
                     beatsSec: Array(stride(from: 0.0, to: 240, by: 0.5)),
                     downbeatsSec: Array(stride(from: 0.0, to: 240, by: 2)),
                     phraseStartsSec: Array(stride(from: 0.0, to: 240, by: 16)),
                     tempoStability: stability, camelotKey: key, integratedLUFS: -14,
                     loudnessCurveLUFS: [], energyCurve: [], hasFadeOut: false,
                     endsInSilence: false, vocalPresence: [], segments: [],
                     mixInSec: 8, mixOutSec: 220, mixable: true,
                     confidence: Confidence(bpm: confidence, downbeats: confidence, key: key == nil ? 0 : 1))
    }
}
