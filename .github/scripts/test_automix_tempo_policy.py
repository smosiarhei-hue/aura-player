"""Exercise the real AutoMix planner against field tempo pairs on Swift CI."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODELS = ROOT / 'Packages/AutoMixV2/Sources/MixModels'
PLANNER = ROOT / 'Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift'


class AutoMixTempoPolicyTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_field_pairs_use_natural_fade(self):
        main = r'''
import Foundation
func profile(_ id: String, _ bpm: Float, confidence: Float = 1, energy: Float? = nil) -> TrackProfile {
    TrackProfile(trackID: TrackID(raw: id), durationSec: 240, sourceSampleRate: 48000,
        sourceBitrateKbps: nil, bpm: bpm,
        beatsSec: Array(stride(from: 0.0, to: 240, by: 0.5)),
        downbeatsSec: Array(stride(from: 0.0, to: 240, by: 2)),
        phraseStartsSec: Array(stride(from: 0.0, to: 240, by: 16)),
        tempoStability: 1, camelotKey: "8A", integratedLUFS: -14,
        loudnessCurveLUFS: [], energyCurve: energy.map { Array(repeating: $0, count: 10) } ?? [], hasFadeOut: false,
        endsInSilence: false, vocalPresence: [], segments: [], mixInSec: 8,
        mixOutSec: 220, mixable: true,
        confidence: Confidence(bpm: confidence, downbeats: confidence, key: 1))
}
func meta(_ id: String) -> TrackMeta {
    TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: nil,
              durationSec: 240, artworkURL: nil)
}
func plan(_ a: Float, _ b: Float, mode: TransitionMode = .automix,
          confidence: Float = 1) -> TransitionPlan {
    MixPlanner.plan(from: profile("a", a, confidence: confidence),
                    to: profile("b", b), aMeta: meta("a"), bMeta: meta("b"),
                    settings: MixSettings(mode: mode))
}
let fieldPairs: [(Float, Float)] = [(99.38, 172.27), (172.27, 63.80),
                                     (60.09, 103.36), (90, 174), (66, 99)]
for (a, b) in fieldPairs {
    let p = plan(a, b)
    precondition(p.type == .crossfade, "wide-tempo pair must not use mashup")
    precondition(p.rateA == 1 && p.rateB == 1 && p.pitchShiftCentsB == 0,
                 "fallback must keep natural speed and pitch")
    precondition(p.loopBarsA == 0 && p.fx.allSatisfy { $0.kind == .volume },
                 "fallback must not schedule rhythmic effects or loops")
    precondition(p.reason.contains("темпы"), "diagnostic reason missing")
}
let cliff = MixPlanner.plan(from: profile("a", 129.2, energy: 0.8),
    to: profile("b", 123, energy: 0.35), aMeta: meta("a"), bMeta: meta("b"),
    settings: MixSettings(mode: .automix))
precondition(cliff.archetype == .spaceReverb && cliff.type == .beatmatchedShort && cliff.bars >= 8,
             "live AutoMix must not select an inaudible 4-bar tape-stop plan")
precondition(plan(120, 128).type != .crossfade, "matched-tempo path regressed")
let balancedPairs: [(Float, Float)] = [(123, 136), (136, 123), (105.5, 94)]
for (a, b) in balancedPairs {
    let match = BeatGridSynchronization.tempoMatch(aBPM: a, bBPM: b)!
    precondition(abs(match.rateA - 1) <= 0.080001 && abs(match.rateB - 1) <= 0.080001)
    precondition(abs(a * match.rateA - b * match.rateB) < 0.001, "rates must really meet")
    let p = plan(a, b)
    precondition(p.type != .crossfade, "moderate field tempo should be planned")
    precondition(abs(p.rateA * a - p.rateB * b) < 0.001)
}
precondition(BeatGridSynchronization.tempoMatch(aBPM: 94, bBPM: 112.3) == nil, "rate limit must be respected")
precondition(plan(120, 128, confidence: 0.4).type == .crossfade, "weak-grid fallback")
precondition(plan(99, 172, mode: .off).type == .none, "off mode changed")
precondition(plan(99, 172, mode: .duet).type != .crossfade, "Duet policy changed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            # Compile unmodified planner declarations with model sources in one module;
            # the sole removed line is the import of that now-local module.
            source = PLANNER.read_text().replace('import MixModels\n', '', 1)
            (path / 'MixPlanner.swift').write_text(source)
            (path / 'main.swift').write_text(main)
            binary = path / 'planner-test'
            subprocess.run(['swiftc', *map(str, sorted(MODELS.glob('*.swift'))),
                            str(path / 'MixPlanner.swift'), str(path / 'main.swift'),
                            '-o', str(binary)], check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)

    def test_live_fallback_route_is_kept(self):
        player = (ROOT / 'Sonivo/playercore.swift').read_text()
        section = player.split('private func scheduleTransitionIfNeeded()', 1)[1].split(
            'private func resolveMashupStyle', 1)[0]
        self.assertIn('plan == nil || plan?.type == .crossfade', section)
        self.assertIn('safeAutomixFallback: true', section)
        self.assertIn('incomingStart: 0', section)
        planner = PLANNER.read_text()
        branch = planner.split('guard let tempo = BeatGridSynchronization.tempoMatch', 1)[1].split(
            '// Проверка фазового расхождения', 1)[0]
        self.assertIn('return crossfade(', branch)
        self.assertNotIn('planEchoFreeze(', branch)

if __name__ == '__main__':
    unittest.main()
