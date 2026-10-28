import Foundation
import MixModels
import MixPlanner
import Testing

private final class RecordingMashupAudio: MashupTransitionAudio, @unchecked Sendable {
    private let lock = NSLock()
    private var _effects: [(FxKind, Float, Deck)] = []
    private var _rates: [(Deck, Float)] = []
    private var _pitches: [(Deck, Float)] = []
    private var _resets = 0

    var effects: [(FxKind, Float, Deck)] {
        lock.lock(); defer { lock.unlock() }
        return _effects
    }

    var pitches: [(Deck, Float)] {
        lock.lock(); defer { lock.unlock() }
        return _pitches
    }

    var resets: Int {
        lock.lock(); defer { lock.unlock() }
        return _resets
    }

    func applyEffect(_ kind: FxKind, value: Float, param: Float?, bpm: Float, to deck: Deck) async {
        lock.lock(); _effects.append((kind, value, deck)); lock.unlock()
    }

    func setRate(_ rate: Float, for deck: Deck) async {
        lock.lock(); _rates.append((deck, rate)); lock.unlock()
    }

    func setPitchCents(_ cents: Float, for deck: Deck) async {
        lock.lock(); _pitches.append((deck, cents)); lock.unlock()
    }

    func resetEffects(_ deck: Deck, preservingRate: Bool) async {
        lock.lock(); _resets += 1; lock.unlock()
    }
}

@Suite("Mashup Transition Executor")
struct MashupTransitionExecutorTests {
    @Test("Compatible house pair prefers bass-swap mashup FX")
    func dropSwapContainsMashupFX() {
        let plan = MixPlanner.plan(
            from: profile("a", bpm: 124, key: "8A"),
            to: profile("b", bpm: 126, key: "8A"),
            aMeta: meta("a"),
            bMeta: meta("b"),
            settings: MixSettings(mode: .automix, skipTransitionsWithinAlbum: false)
        )
        #expect(plan.type == .beatmatchedShort || plan.type == .beatmatchedLong || plan.type == .filterEcho || plan.type == .crossfade)
        #expect(MashupTransitionExecutor.durationSeconds(for: plan) > 0)
        let kinds = Set(plan.fx.map(\.kind))
        #expect(kinds.contains(.volume))
        #expect(kinds.contains(.bassKill) || kinds.contains(.highPass) || kinds.contains(.echoOut))
    }

    @Test("Executor applies bass swap, vocal duck and pitch shift")
    func executorTimeline() async throws {
        let audio = RecordingMashupAudio()
        let plan = TransitionPlan(
            type: .beatmatchedShort,
            archetype: .dropSwap,
            aOutStartSec: 100,
            bInStartSec: 16,
            bars: 2,
            tempoTargetBPM: 120,
            rateA: 1,
            rateB: 1.02,
            pitchShiftCentsB: 100,
            gainOffsetBdB: 0,
            loopBarsA: 0,
            fx: [
                FxEvent(target: .a, kind: .bassKill, startBar: 0, endBar: 2, fromValue: 0, toValue: 1, curve: .linear),
                FxEvent(target: .b, kind: .vocalDucking, startBar: 0, endBar: 1, fromValue: -7, toValue: 0, curve: .sCurve),
                FxEvent(target: .a, kind: .volume, startBar: 0, endBar: 2, fromValue: 0, toValue: -60, curve: .sCurve),
                FxEvent(target: .b, kind: .volume, startBar: 0, endBar: 2, fromValue: -40, toValue: 0, curve: .sCurve)
            ],
            reason: "test"
        )
        try await MashupTransitionExecutor(audio: audio, tickSeconds: 0.2).execute(plan)
        #expect(audio.effects.contains(where: { $0.0 == .bassKill }))
        #expect(audio.effects.contains(where: { $0.0 == .vocalDucking }))
        #expect(audio.pitches.contains(where: { $0.0 == .b && abs($0.1 - 100) < 0.1 }))
        #expect(audio.resets >= 2)
    }

    private func meta(_ id: String, album: String? = nil, duration: Double = 210) -> TrackMeta {
        TrackMeta(
            id: TrackID(raw: id),
            title: id,
            artist: "Test",
            albumID: album,
            durationSec: duration,
            artworkURL: nil
        )
    }

    private func profile(
        _ id: String,
        duration: Double = 210,
        bpm: Float = 124,
        key: String? = "8A",
        lufs: Float = -14
    ) -> TrackProfile {
        TrackProfile(
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
            integratedLUFS: lufs,
            loudnessCurveLUFS: [],
            energyCurve: Array(repeating: 0.6, count: Int(duration)),
            hasFadeOut: false,
            endsInSilence: false,
            vocalPresence: [],
            segments: [Segment(startSec: 64, endSec: 96, type: .drop)],
            mixInSec: 16,
            mixOutSec: 170,
            mixable: true,
            confidence: Confidence(bpm: 0.9, downbeats: 0.9, key: 0.9)
        )
    }
}
