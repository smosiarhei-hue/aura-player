"""Regression checks for AutoMix fallback policy, independent of the iOS test target."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MODELS = ROOT / 'Packages/AutoMixV2/Sources/MixModels'
PLANNER = ROOT / 'Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift'
PLAYER = ROOT / 'Sonivo/playercore.swift'

class AutoMixSafetyChecks(unittest.TestCase):
    def test_player_uses_final_cue_failure_as_pair_scoped_fallback(self):
        src = PLAYER.read_text()
        self.assertIn('var finalGridVerified = false', src)
        self.assertIn('if !duetBake && !finalGridVerified', src)
        self.assertIn('self.automixUnalignedPair = (current.id, nextTrack.id)', src)
        self.assertIn('if finalGridFailed || plan == nil || plan?.type == .crossfade', src)
        self.assertIn('transition.safe-crossfade reason=', src)
        self.assertIn('fx=reverb-wash', src)
        self.assertIn('if automixSafeCrossfade {\n                let wash', src)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_real_swift_planner(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = pathlib.Path(d)
            module = tmp / 'libMixModels.dylib'
            cmd = ['swiftc', '-swift-version', '6', '-emit-library', '-emit-module',
                   '-module-name', 'MixModels', '-emit-module-path', str(tmp / 'MixModels.swiftmodule'),
                   *map(str, sorted(MODELS.glob('*.swift'))), '-o', str(module)]
            subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120)
            main = tmp / 'main.swift'
            main.write_text(r'''
import Foundation
import MixModels
func p(_ id: String, _ key: String, _ bpm: Float, _ duration: Double = 240) -> TrackProfile {
    TrackProfile(trackID: TrackID(raw: id), durationSec: duration, sourceSampleRate: 48000,
        sourceBitrateKbps: nil, bpm: bpm, beatsSec: Array(stride(from: 0.0, to: duration, by: 0.5)),
        downbeatsSec: Array(stride(from: 0.0, to: duration, by: 2)),
        phraseStartsSec: Array(stride(from: 0.0, to: duration, by: 16)), tempoStability: 1,
        camelotKey: key, integratedLUFS: -14, loudnessCurveLUFS: [], energyCurve: [],
        hasFadeOut: false, endsInSilence: false, vocalPresence: [], segments: [],
        mixInSec: 8, mixOutSec: max(0, duration - 20), mixable: true,
        confidence: Confidence(bpm: 1, downbeats: 1, key: 1))
}
func meta(_ id: String, _ duration: Double = 240) -> TrackMeta {
    TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: nil, durationSec: duration, artworkURL: nil)
}
let settings = MixSettings(mode: .automix, skipTransitionsWithinAlbum: false)
let clash = MixPlanner.plan(from: p("a", "6A", 129.2), to: p("b", "9A", 120.19), aMeta: meta("a"), bMeta: meta("b"), settings: settings)
precondition(clash.type == .crossfade && clash.pitchShiftCentsB == 0 && clash.reason.contains("Тональный конфликт"))
let shifted = CamelotCompatibility.match("6A", "12A", maxSemitones: 1)
precondition(shifted.isHarmonicallyViable && abs(shifted.pitchShiftCents) == 100)
precondition(!CamelotCompatibility.match("6A", "12A", maxSemitones: 0).isHarmonicallyViable)
let corrected = MixPlanner.plan(from: p("a", "6A", 120), to: p("b", "12A", 120), aMeta: meta("a"), bMeta: meta("b"), settings: settings)
precondition(corrected.type != .crossfade && corrected.type != .none && abs(corrected.pitchShiftCentsB) == 100)
// Exhaust all major/minor pairs and confirm every nonzero viable shift actually
// lands on a naturally compatible Camelot key and is minimal under its cap.
let minorPC = [8,3,10,5,0,7,2,9,4,11,6,1]
let majorWheel = [11,6,1,8,3,10,5,0,7,2,9,4]
for letterA in ["A", "B"] { for numA in 1...12 { for letterB in ["A", "B"] { for numB in 1...12 {
    let a = "\(numA)\(letterA)", b = "\(numB)\(letterB)"
    let pcs = letterB == "A" ? minorPC : majorWheel
    for cap in 0...2 {
        let result = CamelotCompatibility.match(a, b, maxSemitones: cap)
        let options = (-cap...cap).filter { shift in
            let pc = (pcs[numB - 1] + shift + 12) % 12
            let index = pcs.firstIndex(of: pc)!
            return CamelotCompatibility.areCompatible(a, "\(index + 1)\(letterB)")
        }
        precondition(result.isHarmonicallyViable == !options.isEmpty, "bad viability: \(a) \(b) cap=\(cap)")
        if result.isHarmonicallyViable {
            let shift = Int(result.pitchShiftCents / 100)
            precondition(options.contains(shift) && abs(shift) == options.map { abs($0) }.min()!)
        }
    }
}}}}
let short = MixPlanner.plan(from: p("a", "8A", 120, 30), to: p("b", "8A", 120), aMeta: meta("a", 30), bMeta: meta("b"), settings: settings)
precondition(short.type == .crossfade && short.rateA == 1 && short.rateB == 1)
let good = MixPlanner.plan(from: p("a", "8A", 120), to: p("b", "8B", 120), aMeta: meta("a"), bMeta: meta("b"), settings: settings)
precondition(good.type != .crossfade && good.type != .none)
print("AutoMix planner safety checks passed")
''')
            exe = tmp / 'checks'
            cmd = ['swiftc', '-swift-version', '6', '-I', str(tmp), '-L', str(tmp),
                   '-lMixModels', '-Xlinker', '-rpath', '-Xlinker', str(tmp),
                   str(PLANNER), str(main), '-o', str(exe)]
            subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120)
            subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=30)
