"""Behavior fixtures run on macOS Swift 6; source ownership checked everywhere."""
import pathlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
class MusicHapticsTests(unittest.TestCase):
    def test_audio_clock_not_visual_clock(self):
        manager=(ROOT/'Sonivo/MusicHapticsManager.swift').read_text()
        analyzer=(ROOT/'Sonivo/spectrumanalyzer.swift').read_text()
        self.assertNotIn('processRawBands(values)',analyzer)
        self.assertIn('MusicHapticsManager.shared.submit(snapshot.beatWaveFrame)',analyzer)
        self.assertIn('currentMediaClock()',manager)
        self.assertIn('generation == value',manager)
        self.assertNotIn('asyncAfter',manager)
        self.assertIn('applicationState == .active',manager)
        self.assertIn('now-lastDueAt > 0.1',manager)
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_signal_and_timeline(self):
        model=(ROOT/'Sonivo/MusicHapticSignal.swift').read_text()
        frame=(ROOT/'Sonivo/BeatWaveMotion.swift').read_text().split('/// Positive change')[0]
        fixture='''
func check(_ x: Bool) { if !x { fatalError("fixture failed") } }
var q=MusicHapticTimeline()
var f=BeatWaveAudioFrame(); f.mediaTime=1; f.rms=0.15; f.bass=0.8; f.subBass=0.9
q.push(f); check(q.drain(at: 0.99).isEmpty); check(q.drain(at: 1).count == 1)
q.push(f); check(q.drain(at: 2).isEmpty)
f.mediaTime=Double.nan; q.push(f); check(q.drain(at: 3).isEmpty)
q.reset(); f.mediaTime=0; q.push(f); check(q.drain(at: 0).count == 1)
q.reset(); for i in 0..<1100 { f.mediaTime=Double(i)/100; q.push(f) }
check(q.dropped == 76); check(q.drain(at: 50).count == 1024)
var s=MusicHapticSignal(); f.mediaTime=1; f.kickEventID=5; f.kickConfidence=1
check(s.process(f,ceiling: 0.45,automatic: true).kick == 0)
f.mediaTime=1.01; f.kickEventID=6
let a=s.process(f,ceiling: 0.45,automatic: true); check(a.kick > 0 && a.kick <= 0.45 && a.bass <= 0.45)
f.mediaTime=1.02; check(s.process(f,ceiling: 1,automatic: true).kick == 0)
f.mediaTime=1.03; f.rms=0; f.kickEventID=7
let silence=s.process(f,ceiling: 1,automatic: true); check(silence.kick == 0 && silence.bass == 0)
f.rms=Float.nan; check(s.process(f,ceiling: 1,automatic: true).bass == 0)
s.reset(); f.rms=0.0001; f.mediaTime=2
_ = s.process(f,ceiling: 1,automatic: true); f.mediaTime=2.01; f.kickEventID=8
check(s.process(f,ceiling: 1,automatic: true).kick == 0)
var low=MusicHapticSignal(); var high=MusicHapticSignal()
f.rms=0.01; _ = low.process(f,ceiling: 1,automatic: true)
f.rms=0.5; _ = high.process(f,ceiling: 1,automatic: true)
f.mediaTime=2.02; f.kickEventID=9; f.rms=0.01
let quiet=low.process(f,ceiling: 1,automatic: true).kick
f.rms=0.5; check(high.process(f,ceiling: 1,automatic: true).kick > quiet)
print("Music haptics causal timeline and signal fixtures passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory); (p/'main.swift').write_text(frame+model+fixture)
            subprocess.run(['swiftc','-swift-version','6',str(p/'main.swift'),'-o',str(p/'test')],check=True,capture_output=True,text=True)
            subprocess.run([str(p/'test')],check=True)
