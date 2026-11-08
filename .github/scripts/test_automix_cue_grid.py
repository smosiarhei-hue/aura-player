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
precondition(cues(rate: 1.05) == nil, "must reserve source audio at shifted speed")
precondition(cues(b: 3.9, beatsB: [3.9]) == nil, "must not bypass intro floor")
precondition(cues(b: 9.8, beatsB: [10]) == nil, "must not snap forward into incoming vocal")
precondition(cues(a: .nan) == nil, "nonfinite cue accepted")
precondition(cues(beatsA: [.nan, .infinity]) == nil, "invalid grid accepted")
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
        self.assertIn('notBefore: max(self.playbackProgress + 0.25, outP.mixOutSec)', segment)
        self.assertIn('cue.downbeats unavailable', segment)

if __name__ == '__main__':
    unittest.main()
