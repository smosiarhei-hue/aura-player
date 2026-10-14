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
    def test_modes_strength_settings_and_nonstacking_driver(self):
        theme=(ROOT/'Sonivo/theme.swift').read_text()
        ui=(ROOT/'Sonivo/settingsview.swift').read_text()
        driver=(ROOT/'Sonivo/MusicHapticsManager.swift').read_text()
        signal=(ROOT/'Sonivo/MusicHapticSignal.swift').read_text()
        for binding in ["$settings.musicHapticsMode", "$settings.musicHapticsAutomatic", "$settings.musicHapticsIntensity"]:
            self.assertIn(binding,ui)
        for mapping in ["case .soft: return 0.35","case .medium: return 0.70","case .strong: return 1.00"]:
            self.assertIn(mapping,theme)
        self.assertIn('settings.musicHapticsMode',theme)
        self.assertIn('guard mode == .full else { return output }',signal)
        self.assertIn('output.body=strength',signal)
        self.assertNotIn('strength*unit(frame.kickConfidence)',signal)
        self.assertIn('submitted >= self.kickBodyUntil',driver)
        self.assertIn('value: min(1,output.kick)',driver)
        self.assertNotIn('value: scale*0.45',driver)
        self.assertIn('hapticSharpness,value: 0)',driver)

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
let a=s.process(f,ceiling: 0.45,automatic: true); check(a.kick > 0 && a.kick <= 0.45 && a.body <= 0.45)
f.mediaTime=1.02; check(s.process(f,ceiling: 1,automatic: true).kick == 0)
f.mediaTime=1.03; f.rms=0; f.kickEventID=7
let silence=s.process(f,ceiling: 1,automatic: true); check(silence.kick == 0 && silence.body == 0)
f.rms=Float.nan; check(s.process(f,ceiling: 1,automatic: true).body == 0)
s.reset(); f.rms=0.0001; f.mediaTime=2
_ = s.process(f,ceiling: 1,automatic: true); f.mediaTime=2.01; f.kickEventID=8
check(s.process(f,ceiling: 1,automatic: true).kick == 0)
var low=MusicHapticSignal(); var high=MusicHapticSignal()
f.rms=0.01; _ = low.process(f,ceiling: 1,automatic: true)
f.rms=0.5; _ = high.process(f,ceiling: 1,automatic: true)
f.mediaTime=2.02; f.kickEventID=9; f.rms=0.01
let quiet=low.process(f,ceiling: 1,automatic: true).kick
f.rms=0.5; check(high.process(f,ceiling: 1,automatic: true).kick > quiet)
// Distinct fixed ceilings, no confidence attenuation after a confirmed event.
for ceiling in [Float(0.35),Float(0.70),Float(1)] {
    var fixed=MusicHapticSignal(); f.mediaTime=3; f.rms=0.05; f.kickEventID=10; f.kickConfidence=0.55
    _ = fixed.process(f,ceiling: ceiling,automatic: false,mode: .beat)
    f.mediaTime=3.01; f.kickEventID=11
    let beat=fixed.process(f,ceiling: ceiling,automatic: false,mode: .beat)
    check(abs(beat.kick-ceiling)<0.00001 && beat.body == 0 && beat.treble == 0)
    f.mediaTime=3.02
    let held=fixed.process(f,ceiling: ceiling,automatic: false,mode: .beat)
    check(held.kick == 0 && held.body == 0)
}
var full=MusicHapticSignal(); f.mediaTime=4; f.rms=0.2; f.kickEventID=20
_ = full.process(f,ceiling: 1,automatic: true,mode: .full)
f.mediaTime=4.01; f.kickEventID=21
let peak=full.process(f,ceiling: 1,automatic: true,mode: .full)
check(peak.kick == 1 && peak.body == 1)
f.mediaTime=4.02; f.bass=0; f.subBass=0; f.mids=0.8
let vocals=full.process(f,ceiling: 0.70,automatic: false,mode: .full)
check(vocals.kick == 0 && vocals.body == 0.70 && vocals.bodySharpness>=0 && vocals.bodySharpness<=1)
f.mediaTime=4.03; f.rms=0
let stopped=full.process(f,ceiling: 1,automatic: false,mode: .full)
check(stopped.kick == 0 && stopped.body == 0 && stopped.treble == 0)
f.mediaTime=4.04; f.rms=0.5; f.highs=Float.infinity
let invalid=full.process(f,ceiling: Float.nan,automatic: false,mode: .full)
check(invalid.body == 0 && invalid.kick == 0 && invalid.bodySharpness.isFinite)
print("Music haptics causal timeline, modes and full-range strength fixtures passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            p=pathlib.Path(directory); (p/'main.swift').write_text(frame+model+fixture)
            subprocess.run(['swiftc','-swift-version','6',str(p/'main.swift'),'-o',str(p/'test')],check=True,capture_output=True,text=True)
            subprocess.run([str(p/'test')],check=True)
