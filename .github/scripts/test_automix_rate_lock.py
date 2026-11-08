"""Exercise production rate envelopes; rendered scheduling still needs device testing."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / 'Packages/AutoMixV2/Sources'

class AutoMixRateLockTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_two_decks_keep_common_tempo_until_land(self):
        main = r'''
import Foundation
func check(_ a: Float, _ b: Float, expectNaturalAtLand: Bool) {
    var style = MashupLiveStyle.fallback
    style.isBeatmatched = true
    style.rateA = a
    style.rateB = b
    style.archetypeName = "echoFreeze"
    style.handoffAt = 0.86
    style.moodLand = 0.86
    let start = style.playbackRates(progress: 0)
    precondition(abs(start.outgoing - a) < 0.00001 && abs(start.incoming - b) < 0.00001)
    for i in 0...860 {
        let rates = style.playbackRates(progress: Double(i) / 1000)
        precondition(rates.outgoing >= 0.91999 && rates.outgoing <= 1.08001)
        precondition(rates.incoming >= 0.91999 && rates.incoming <= 1.08001)
        // Rates are target/natural BPM, so equal scale keeps both BPMs equal.
        precondition(abs(rates.outgoing / a - rates.incoming / b) < 0.00001,
                     "matched decks drift apart")
    }
    let land = style.playbackRates(progress: style.automixLandProgress)
    if expectNaturalAtLand { precondition(abs(land.incoming - 1) < 0.00001) }
}
check(1, 1.05, expectNaturalAtLand: true)
check(1, 0.95, expectNaturalAtLand: true)
check(1.07, 1, expectNaturalAtLand: true)
check(0.92, 1.08, expectNaturalAtLand: false)
var duet = MashupLiveStyle.fallback
duet.isDuet = true
duet.isBeatmatched = true
duet.rateA = 1.04
duet.rateB = 0.96
let duetEnd = duet.playbackRates(progress: 1)
precondition(abs(duetEnd.outgoing - 1) < 0.00001 && abs(duetEnd.incoming - 1) < 0.00001,
             "duet behavior changed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            for name in ('MixPlanner.swift', 'MashupLiveStyle.swift'):
                source = (SOURCES / 'MixPlanner' / name).read_text()
                (path / name).write_text(source.replace('import MixModels\n', '', 1))
            (path / 'main.swift').write_text(main)
            binary = path / 'rate-lock-test'
            subprocess.run(['swiftc', *map(str, sorted((SOURCES / 'MixModels').glob('*.swift'))),
                            str(path / 'MixPlanner.swift'), str(path / 'MashupLiveStyle.swift'),
                            str(path / 'main.swift'), '-o', str(binary)],
                           check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)

    def test_production_player_uses_rate_envelope(self):
        player = (ROOT / 'Sonivo/playercore.swift').read_text()
        tick = player.split('private func tickTransition()', 1)[1].split('private func applyMashupTimePitch', 1)[0]
        self.assertIn('activeMashupStyle.playbackRates(progress: p)', tick)
        self.assertIn('rate: beatRates.outgoing', tick)
        self.assertIn('rate: beatRates.incoming', tick)

if __name__ == '__main__':
    unittest.main()
