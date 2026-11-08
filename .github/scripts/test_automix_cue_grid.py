"""Regression tests for retaining measured cue positions after retargeting."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'Packages/AutoMixV2/Sources'

class AutoMixCueGridTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_bounded_measured_downbeats(self):
        main = r'''
import Foundation
// Build 1199: the real eight-bar plan was moved from 150s to 170.5s.
let eightBars = 8 * 240.0 / 129.2
let planned = MashupBlendScheduler.plannedCueIfUsable(
    cue: 150, duration: 182.5, blend: eightBars, outgoingRate: 1)
precondition(planned == 150, "valid planned cue must not be tail aligned")
precondition(abs(MashupBlendScheduler.plannedLandProgress(bars: 8) - 0.875) < 0.000001)
precondition(MashupBlendScheduler.plannedCueIfUsable(
    cue: 170, duration: 182.5, blend: eightBars, outgoingRate: 1) == nil, "reject insufficient tail")
precondition(MashupBlendScheduler.plannedCueIfUsable(
    cue: 130, duration: 182.5, blend: eightBars, outgoingRate: 1) == nil, "respect song body")
precondition(MashupBlendScheduler.plannedCueIfUsable(
    cue: .nan, duration: 182.5, blend: eightBars, outgoingRate: 1) == nil)
let earlyGrid = MashupBlendScheduler.retargetToDownbeats(
    outgoingCue: 150, incomingCue: 5.1, outgoingDuration: 182.5, incomingDuration: 133.9,
    blend: eightBars, outgoingRate: 1, notBefore: 138.5,
    outgoingBPM: 129.2, incomingBPM: 126.05,
    outgoingDownbeats: [149.9, 151.8], incomingDownbeats: [5.09])
precondition(earlyGrid?.outgoing == 149.9 && earlyGrid?.incoming == 5.09,
             "earlier plan must still use measured downbeats")
func cues(a: Double = 179.8, b: Double = 10.2, rate: Double = 1,
          notBefore: Double = 160, beatsA: [Double] = [178, 180],
          beatsB: [Double] = [8, 10]) -> (outgoing: Double, incoming: Double)? {
    MashupBlendScheduler.retargetToDownbeats(
        outgoingCue: a, incomingCue: b, outgoingDuration: 200, incomingDuration: 200,
        blend: 20, outgoingRate: rate, notBefore: notBefore,
        outgoingBPM: 120, incomingBPM: 120,
        outgoingDownbeats: beatsA, incomingDownbeats: beatsB)
}
let result = cues()
precondition(result?.outgoing == 180 && result?.incoming == 10, "failed to recover measured beats")
precondition(cues(a: 179.0) == nil, "must not force distant cues")
precondition(cues(notBefore: 180.1) == nil, "must not move behind playhead")
precondition(cues(rate: 1.05)?.outgoing == 178, "tail snap must reserve source audio at shifted speed")
precondition(cues(rate: 1.05, beatsA: [180]) == nil, "must reject downbeat beyond accelerated tail")
precondition(cues(b: 3.9, beatsB: [3.9]) == nil, "must not bypass intro floor")
precondition(cues(b: 9.8, beatsB: [10]) == nil, "must not snap forward into incoming vocal")
precondition(cues(a: .nan) == nil, "nonfinite cue accepted")
precondition(cues(beatsA: [.nan, .infinity]) == nil, "invalid grid accepted")
func tail(outgoing: [Double], incoming: [Double] = [8.8],
          notBefore: Double = 147.45, cue: Double = 191.9) -> (outgoing: Double, incoming: Double)? {
    MashupBlendScheduler.retargetToDownbeats(
        outgoingCue: cue, incomingCue: 8.8, outgoingDuration: 198.3, incomingDuration: 125.3,
        blend: 6.4, outgoingRate: 1, notBefore: notBefore,
        outgoingBPM: 117.45, incomingBPM: 109.96,
        outgoingDownbeats: outgoing, incomingDownbeats: incoming)
}
// Build 1195: mood retarget moved 164.5 to 191.9, leaving no room
// to snap forward. Recover a real earlier downbeat, not a synthetic grid.
precondition(tail(outgoing: [190.3])?.outgoing == 190.3)
precondition(tail(outgoing: [189.7]) == nil, "must not move more than one bar")
precondition(tail(outgoing: [190.3], notBefore: 190.4) == nil, "must not move behind the playhead")
precondition(tail(outgoing: [190.3], incoming: [9.0]) == nil, "must not move B into a later vocal")
precondition(tail(outgoing: [190.3], cue: 190.0) != nil, "normal nearby snap should still work")
precondition(tail(outgoing: [190.3], cue: 189.3) == nil, "non-tail cue must retain strict radius")
let accelerated = MashupBlendScheduler.retargetToDownbeats(
    outgoingCue: 191.9, incomingCue: 8.8, outgoingDuration: 198.3, incomingDuration: 125.3,
    blend: 6.4, outgoingRate: 1.08, notBefore: 147.45, outgoingBPM: 117.45, incomingBPM: 109.96,
    outgoingDownbeats: [190.3, 191.5], incomingDownbeats: [8.8])
precondition(accelerated?.outgoing == 190.3, "recover tail while reserving accelerated source")
precondition(accelerated!.outgoing + 6.4 * 1.08 <= 198.3, "accelerated A runs past EOF")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            for name in ('MixPlanner.swift', 'MashupBlendScheduler.swift'):
                src = (SOURCES / 'MixPlanner' / name).read_text().replace('import MixModels\n', '', 1)
                (path / name).write_text(src)
            (path / 'main.swift').write_text(main)
            binary = path / 'cue-grid-test'
            subprocess.run(['swiftc', *map(str, sorted((SOURCES / 'MixModels').glob('*.swift'))),
                            str(path / 'MixPlanner.swift'), str(path / 'MashupBlendScheduler.swift'),
                            str(path / 'main.swift'), '-o', str(binary)], check=True,
                           capture_output=True, text=True, timeout=120)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)

    def test_player_retargets_before_bake(self):
        player = (ROOT / 'Sonivo/playercore.swift').read_text()
        segment = player.split('private func scheduleSimpleTransition(', 1)[1]
        self.assertLess(segment.index('MashupBlendScheduler.retargetToDownbeats('),
                        segment.index('let bakeCueA = cueA'))
        self.assertIn('outP.confidence.downbeats >= 0.65', segment)
        self.assertIn('notBefore: self.playbackProgress + 0.25', segment)
        self.assertIn('cue.downbeats unavailable', segment)
        self.assertIn('MashupBlendScheduler.plannedCueIfUsable(', player)
        self.assertIn('source = "planned"', player)
        wait = player.split('private func waitUntilMashupCue(', 1)[1].split('private func firePendingMashupLiveArmIfNeeded()', 1)[0]
        self.assertIn('if pos >= safeCue { return true }', wait)
        self.assertNotIn('pos + 0.25 >= safeCue', wait)
        self.assertNotIn('estimated + 0.25 >= safeCue', wait)

if __name__ == '__main__':
    unittest.main()
