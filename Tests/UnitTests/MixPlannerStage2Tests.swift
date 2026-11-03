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
                                   settings: MixSettings(mode: .crossfade, crossfadeSeconds: 6, loudnessNormalization: true))
        #expect(plan.type == .crossfade)
        #expect(plan.bars == 6)
        #expect(plan.aOutStartSec == 160)
        #expect(plan.bInStartSec == 8)
        #expect(plan.gainOffsetBdB == 6)
        #expect(plan.fx.count == 2)
    }

    @Test("Default playback does not change source loudness")
    func originalLevel() {
        let plan = MixPlanner.plan(from: profile("a", lufs: -14), to: profile("b", lufs: -8),
                                   aMeta: meta("a"), bMeta: meta("b"),
                                   settings: MixSettings(mode: .crossfade))
        #expect(plan.gainOffsetBdB == 0)
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

    @Test("Duet plans vocal stack when tempo and Camelot lock")
    func duetQualityGatePass() {
        let a = profile("a", bpm: 124, key: "8A")
        let b = profile("b", bpm: 126, key: "8A")
        let plan = MixPlanner.plan(
            from: a, to: b,
            aMeta: meta("a"), bMeta: meta("b"),
            settings: MixSettings(mode: .duet, skipTransitionsWithinAlbum: false)
        )
        #expect(plan.type != .none)
        #expect(plan.reason.hasPrefix("DUET ·"))
        #expect(plan.tempoTargetBPM > 30)
        #expect(plan.bars >= 2)
        #expect(plan.fx.contains { $0.kind == .echoOut })
        #expect(plan.fx.contains { $0.kind == .highPass })
        #expect(!plan.fx.contains { $0.kind == .instrumentalize })
    }

    @Test("Duet stays dual-vocal soft plan when BPM cannot lock")
    func duetQualityGateSoft() {
        let a = profile("a", bpm: 90, key: "8A")
        let b = profile("b", bpm: 140, key: "8A")
        let plan = MixPlanner.plan(
            from: a, to: b,
            aMeta: meta("a"), bMeta: meta("b"),
            settings: MixSettings(mode: .duet, skipTransitionsWithinAlbum: false)
        )
        #expect(plan.reason.hasPrefix("DUET · soft"))
        #expect(!plan.fx.contains { $0.kind == .instrumentalize })
        #expect(plan.fx.contains { $0.kind == .echoOut })
    }

    @Test("Automix plans differ across harmonic / energy / key-clash pairs")
    func automixPlansVaryPerPair() {
        let settings = MixSettings(mode: .automix, skipTransitionsWithinAlbum: false)
        let match = MixPlanner.plan(
            from: profile("m1", bpm: 124, key: "8A", energy: 0.5),
            to: profile("m2", bpm: 126, key: "8A", energy: 0.55),
            aMeta: meta("m1"), bMeta: meta("m2"),
            settings: settings
        )
        let clash = MixPlanner.plan(
            from: profile("c1", bpm: 128, key: "11A", energy: 0.55),
            to: profile("c2", bpm: 129, key: "5A", energy: 0.55),
            aMeta: meta("c1"), bMeta: meta("c2"),
            settings: settings
        )
        let cliff = MixPlanner.plan(
            from: profile("t1", bpm: 122, key: "8A", energy: 0.8),
            to: profile("t2", bpm: 124, key: "8A", energy: 0.35),
            aMeta: meta("t1"), bMeta: meta("t2"),
            settings: settings
        )
        #expect(match.archetype != clash.archetype || abs(match.bars - clash.bars) > 0.5)
        #expect(match.reason != clash.reason)
        #expect(cliff.archetype == .tapeStop || cliff.reason != match.reason)
        #expect(Set([match.archetype, clash.archetype, cliff.archetype]).count >= 2)
    }

    private func meta(_ id: String, album: String? = nil, duration: Double = 180) -> TrackMeta {
        TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: album,
                  durationSec: duration, artworkURL: nil)
    }

    private func profile(
        _ id: String,
        duration: Double = 180,
        lufs: Float = -14,
        bpm: Float = 120,
        key: String? = nil,
        energy: Float = 0.5
    ) -> TrackProfile {
        TrackProfile(trackID: TrackID(raw: id), durationSec: duration,
                     sourceSampleRate: 44_100, sourceBitrateKbps: 320,
                     bpm: bpm, beatsSec: Array(stride(from: 0.0, to: duration, by: 0.5)),
                     downbeatsSec: Array(stride(from: 0.0, to: duration, by: 2)),
                     phraseStartsSec: Array(stride(from: 0.0, to: duration, by: 16)),
                     tempoStability: 1, camelotKey: key, integratedLUFS: lufs,
                     loudnessCurveLUFS: [], energyCurve: Array(repeating: energy, count: Int(duration)),
                     hasFadeOut: false, endsInSilence: false,
                     vocalPresence: Array(repeating: 0.55, count: Int(duration * 4)),
                     segments: [], mixInSec: 8, mixOutSec: 160, mixable: true,
                     confidence: Confidence(bpm: 1, downbeats: 1, key: key == nil ? 0 : 1))
    }
}
