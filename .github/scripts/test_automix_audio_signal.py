"""DSP regressions: exercise the production Swift loop and stem mixer on macOS CI."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORE = ROOT / "Packages/AutoMixV2/Sources/AudioEngineCore"

class AutoMixAudioSignalTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("swiftc"), "Swift compiler unavailable")
    def test_production_loop_and_stem_mix(self):
        source = r'''
import Foundation
func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.0001) -> Bool {
    abs(a - b) < tolerance
}
let rate = 10_000.0
let period = 5_000
var left = [Float](repeating: 0, count: 22_000)
left[1000] = 0.8
var right = left
StemMashupGlue.tilePhraseLoop(&left, &right, rate: rate, loopSec: 0.5, until: 20_000)
for repetition in 0..<4 {
    precondition(close(left[repetition * period + 1000], 0.8), "loop beat drift")
    precondition(close(right[repetition * period + 1000], 0.8), "stereo beat drift")
}
var sine = (0..<22_000).map { Float(sin(Double($0) * 0.031)) }
var sineR = sine
StemMashupGlue.tilePhraseLoop(&sine, &sineR, rate: rate, loopSec: 0.5, until: 20_000)
for seam in [5000, 10000, 15000] {
    precondition(abs(sine[seam] - sine[seam - 1]) < 0.04, "loop seam click")
}
var badL = [Float](repeating: 0.5, count: 5000)
var badR = [Float](repeating: 0.5, count: 10)
StemMashupGlue.tilePhraseLoop(&badL, &badR, rate: rate, loopSec: 0.1, until: 5000)
StemMashupGlue.tilePhraseLoop(&badL, &badR, rate: rate, loopSec: .nan, until: 5000)
let signal = [Float](repeating: 0.9, count: 1000)
let mixed = HTDemucsWindowMixer.render(dryL: signal, dryR: signal, stemL: signal, stemR: signal,
                                        amount: 1, untilFrame: 900, fadeFrames: 200)
precondition(mixed.left.allSatisfy { close($0, 0.9) }, "correlated fade gain bump")
precondition(mixed.right.allSatisfy { close($0, 0.9) }, "stereo fade gain bump")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / "main.swift").write_text(source)
            binary = path / "signal-test"
            subprocess.run(["swiftc", str(CORE / "StemMashupGlue.swift"),
                            str(CORE / "StemSplit/HTDemucsWindowMixer.swift"),
                            str(path / "main.swift"), "-o", str(binary)],
                           check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)

    def test_safety_guards_remain_in_live_paths(self):
        player = (ROOT / "Sonivo/playercore.swift").read_text()
        handoff = player.split("private func safeAutomixHandoffPosition", 1)[1].split("private func verifyAutomixHandoffPlayback", 1)[0]
        self.assertNotIn("downbeatsSec", handoff)
        self.assertIn("plan.type == .none { return }", player)
        style = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift").read_text()
        self.assertIn("plan.type != .crossfade, plan.type != .none", style)
        analyzer = (ROOT / "Packages/AutoMixV2/Sources/TrackAnalysis/TrackAnalyzer.swift").read_text()
        self.assertIn("guard maxLag >= minLag else { return (0, 0) }", analyzer)

if __name__ == "__main__":
    unittest.main()
