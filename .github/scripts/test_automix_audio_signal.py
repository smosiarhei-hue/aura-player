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
// 1.05 from a real AutoMix plan must not be silently clipped to 1.04.
precondition(abs(HTDemucsWindowMixer.automixBakeRate(1.05) - 1.05) < 0.000001)
precondition(abs(HTDemucsWindowMixer.automixBakeRate(0.93) - 0.93) < 0.000001)
precondition(HTDemucsWindowMixer.automixBakeRate(2) == 1.08)
precondition(HTDemucsWindowMixer.automixBakeRate(0) == 0.92)
precondition(HTDemucsWindowMixer.automixBakeRate(.nan) == 1)
let signal = [Float](repeating: 0.9, count: 1000)
let mixed = HTDemucsWindowMixer.render(dryL: signal, dryR: signal, stemL: signal, stemR: signal,
                                        amount: 1, untilFrame: 900, fadeFrames: 200)
precondition(mixed.left.allSatisfy { close($0, 0.9) }, "correlated fade gain bump")
precondition(mixed.right.allSatisfy { close($0, 0.9) }, "stereo fade gain bump")
var previous: Float = -1
for i in 0...1000 {
    let gains = AutoMixSafeCrossfade.gains(progress: Double(i) / 1000)
    precondition(gains.incoming >= previous, "non-monotonic fallback")
    precondition(close(gains.outgoing + gains.incoming, 1), "fallback gain boost")
    precondition(gains.outgoing >= 0 && gains.incoming >= 0, "negative gain")
    previous = gains.incoming
}
let start = AutoMixSafeCrossfade.gains(progress: 0)
let end = AutoMixSafeCrossfade.gains(progress: 1)
precondition(start.outgoing == 1 && start.incoming == 0, "fallback start")
precondition(end.outgoing == 0 && end.incoming == 1, "fallback end")
precondition(AutoMixSafeCrossfade.gains(progress: .nan).outgoing == 1, "nonfinite fallback")
let packed = HTDemucsTensorLayout.checked(shape: [1, 8, 4], strides: [32, 4, 1], count: 32, frames: 4)
precondition(packed?.channelBases == [0,4,8,12,16,20,24,28] && packed?.frameStride == 1, "packed layout")
let separated = HTDemucsTensorLayout.checked(shape: [1, 4, 2, 4], strides: [32, 8, 4, 1], count: 32, frames: 4)
precondition(separated?.channelBases == packed?.channelBases, "stem-major layout")
let transposed = HTDemucsTensorLayout.checked(shape: [1, 8, 4], strides: [32, 1, 8], count: 32, frames: 4)
precondition(transposed?.channelBases == [0,1,2,3,4,5,6,7] && transposed?.frameStride == 8, "dense transposed layout")
precondition(HTDemucsTensorLayout.checked(shape: [1, 8, 3], strides: [24, 3, 1], count: 24, frames: 4) == nil, "short model output")
precondition(HTDemucsTensorLayout.checked(shape: [1, 3, 2, 4], strides: [24, 8, 4, 1], count: 24, frames: 4) == nil, "missing stem")
precondition(HTDemucsTensorLayout.checked(shape: [1, 8, 4], strides: [32, 1, 1], count: 32, frames: 4) == nil, "overlapping strides")
precondition(HTDemucsTensorLayout.checked(shape: [1, 8, 4], strides: [40, 5, 1], count: 32, frames: 4) == nil, "padded strides")
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)
            (path / "main.swift").write_text(source)
            binary = path / "signal-test"
            subprocess.run(["swiftc", str(CORE / "StemMashupGlue.swift"),
                            str(CORE / "StemSplit/HTDemucsWindowMixer.swift"),
                            str(CORE / "StemSplit/HTDemucsTensorLayout.swift"),
                            str(CORE / "CrossfadeCurve.swift"), str(path / "main.swift"), "-o", str(binary)],
                           check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=30)

    def test_safety_guards_remain_in_live_paths(self):
        player = (ROOT / "Sonivo/playercore.swift").read_text()
        handoff = player.split("private func safeAutomixHandoffPosition", 1)[1].split("private func verifyAutomixHandoffPlayback", 1)[0]
        self.assertNotIn("downbeatsSec", handoff)
        self.assertIn("plan.type == .none { return }", player)
        self.assertIn("plan == nil || plan?.type == .crossfade", player)
        self.assertIn("safeAutomixFallback: true", player)
        self.assertGreaterEqual(player.count("AutoMixSafeCrossfade.gains(progress:"), 2)
        self.assertIn("targetStream.timeControlStatus == .playing", player)
        self.assertIn("automixSafeCrossfade && (!incomingLaneReady", player)
        self.assertIn("safeCrossfadeStalledAt", player)
        self.assertIn("activeTransitionMode = transitionMode", player)
        self.assertIn("activeTransitionMode ?? transitionMode", player)
        self.assertIn("analysisGeneration == request", (ROOT / "Sonivo/AutoMixV2AnalysisRuntime.swift").read_text())
        runtime = (ROOT / "Sonivo/AutoMixV2AnalysisRuntime.swift").read_text()
        self.assertIn('observedPair == key + "|" + mixSettingsMode.rawValue', runtime)
        self.assertIn("observedPair == bakeToken", runtime)
        self.assertIn("try await Self.prepareAnalysisURL", runtime)
        style = (ROOT / "Packages/AutoMixV2/Sources/MixPlanner/MashupLiveStyle.swift").read_text()
        self.assertIn("plan.type != .crossfade, plan.type != .none", style)
        analyzer = (ROOT / "Packages/AutoMixV2/Sources/TrackAnalysis/TrackAnalyzer.swift").read_text()
        self.assertIn("guard maxLag >= minLag else { return (0, 0) }", analyzer)
        neural_bake = (CORE / "StemSplit/HTDemucsMashupBake.swift").read_text()
        hybrid_bake = (CORE / "MidSideStemBaker.swift").read_text()
        self.assertIn("HTDemucsWindowMixer.automixBakeRate(playbackRate)", neural_bake)
        self.assertIn("HTDemucsWindowMixer.automixBakeRate(playbackRate)", hybrid_bake)
        separator = (CORE / "StemSplit/CoreMLStemSeparator.swift").read_text()
        self.assertIn("HTDemucsTensorLayout.checked(", separator)
        self.assertIn("input.right.count == n", separator)
        self.assertIn("guard sample.isFinite", separator)
        late = player.split("let late = await bakeTask.result", 1)[1].split("do {", 1)[0]
        self.assertIn('reason=live-started', late)
        self.assertIn("self.executionTransitionMode == .automix", late)
        self.assertIn("MidSideStemBaker.removeTempFiles", late)

if __name__ == "__main__":
    unittest.main()
