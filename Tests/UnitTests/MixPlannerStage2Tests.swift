// Path: Tests/UnitTests/MixPlannerStage2Tests.swift

import MixModels
import MixPlanner
import Testing

@Suite("MixPlanner Stage 2")
struct MixPlannerStage2Tests {
    @Test("Off mode produces no transition")
    func off() {
        let plan = MixPlanner.plan(from: profile("a"), to: profile("b"),
                                   aMeta: meta("a"), bMeta: meta("b"),
                                   settings: MixSettings(mode: .off))
        #expect(plan.type == .none)
        #expect(plan.reason.isEmpty == false)
    }

    @Test("Crossfade uses cue points and normalization")
    func crossfade() {
        let plan = MixPlanner.plan(from: profile("a", lufs: -14),
                                   to: profile("b", lufs: -20),
                                   aMeta: meta("a"), bMeta: meta("b"),
                                   settings: MixSettings(mode: .crossfade, crossfadeSeconds: 6))
        #expect(plan.type == .crossfade)
        #expect(plan.bars == 6)
        #expect(plan.aOutStartSec == 160)
        #expect(plan.bInStartSec == 8)
        #expect(plan.gainOffsetBdB == 6)
        #expect(plan.fx.count == 2)
    }

    @Test("Gapless album and short tracks produce none")
    func exclusions() {
        let same = MixPlanner.plan(from: profile("a"), to: profile("b"),
                                   aMeta: meta("a", album: "x"), bMeta: meta("b", album: "x"),
                                   settings: MixSettings())
        #expect(same.type == .none)
        let short = MixPlanner.plan(from: profile("a", duration: 59), to: profile("b"),
                                    aMeta: meta("a", duration: 59), bMeta: meta("b"),
                                    settings: MixSettings(skipTransitionsWithinAlbum: false))
        #expect(short.type == .none)
    }

    private func meta(_ id: String, album: String? = nil, duration: Double = 180) -> TrackMeta {
        TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: album,
                  durationSec: duration, artworkURL: nil)
    }

    private func profile(_ id: String, duration: Double = 180, lufs: Float = -14) -> TrackProfile {
        TrackProfile(trackID: TrackID(raw: id), durationSec: duration,
                     sourceSampleRate: 44_100, sourceBitrateKbps: 320,
                     bpm: 120, beatsSec: Array(stride(from: 0.0, to: duration, by: 0.5)),
                     downbeatsSec: Array(stride(from: 0.0, to: duration, by: 2)),
                     phraseStartsSec: Array(stride(from: 0.0, to: duration, by: 16)),
                     tempoStability: 1, camelotKey: nil, integratedLUFS: lufs,
                     loudnessCurveLUFS: [], energyCurve: Array(repeating: 0.5, count: Int(duration)),
                     hasFadeOut: false, endsInSilence: false, vocalPresence: [],
                     segments: [], mixInSec: 8, mixOutSec: 160, mixable: true,
                     confidence: Confidence(bpm: 1, downbeats: 1, key: 0))
    }
}
