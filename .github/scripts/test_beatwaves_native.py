"""Native handoff invariants; numerical Swift executable also runs on the macOS builder."""
import unittest, pathlib, tempfile, subprocess, shutil
ROOT=pathlib.Path(__file__).resolve().parents[2]

class BeatWaveNativeTests(unittest.TestCase):
    def test_native_only_single_pass_promotion_gpu(self):
        s=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('beatWaveField',s)
        self.assertNotIn('beatWaveGlass',s)
        self.assertNotIn('fieldTexture',s)
        self.assertIn('view.isPaused=true',s)
        self.assertIn('inFlight.wait(timeout: .now())',s)
        self.assertIn('CADisplayLink(target:',s)
        self.assertIn('preferredFrameRateRange',s)
        self.assertIn('maximumFramesPerSecond',s)
        self.assertIn('min(120,maximum)',s)
        self.assertIn('forMode: .common',s)
        self.assertIn('displayLink?.invalidate()',s)
        self.assertIn('weak var renderer',s)
        self.assertIn('gpuEndTime-buffer.gpuStartTime',s)
        self.assertNotIn('AVPlayer(',s); self.assertNotIn('WKWebView',s)
        self.assertEqual(s.count('drawPrimitives('),1)
        self.assertIn('CADisableMinimumFrameDurationOnPhone: true',(ROOT/'project.yml').read_text())

    def test_actual_capture_timestamp_and_single_event(self):
        a=(ROOT/'Sonivo/spectrumanalyzer.swift').read_text()
        self.assertIn('beatWaveDetector.process(beatFrame)',a)
        self.assertIn('snapshot.beatWaveFrame.capturedAt',a)
        self.assertIn('channel[i] * channel[i]',a)
        h=(ROOT/'Sonivo/MusicHapticsManager.swift').read_text()
        self.assertIn('eventID > self.lastBeatWaveEventID',h)
        self.assertIn('!isBeatWaveOverrideActive',h)
        self.assertIn('settings.musicHaptics',h)
        self.assertIn('playsHapticsOnly = true',h)
        v=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('if newKick',v)
        self.assertIn('eventID: frame.kickEventID',v)

    def test_visualization_has_no_glass_and_premultiplied_alpha(self):
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        for unwanted in ['beatWaveGlass','sdRoundedRect','rimBevel','glassHalfSize',
                         'uGlass','shadowAlpha','beatWaveSample']:
            self.assertNotIn(unwanted,m)
        self.assertIn('rgb * alpha',m)
        self.assertIn('noise.sample(beatNoiseSampler',m)
        self.assertIn('uPulseSpeed 2.4',m)
        self.assertIn('uSegmentSpeed 1.2',m)
        self.assertIn('strands[i].pigment.rgb',m)
        self.assertIn('float featherX = smoothstep',m)
        self.assertIn('float featherY = smoothstep',m)

    def test_scoped_lifecycle_and_no_fake_clock(self):
        s=(ROOT/'Sonivo/MusicWaveBackground.swift').read_text()
        r=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        for item in ['!reduceMotion && scenePhase == .active',
                     '.allowsHitTesting(false)', '.accessibilityHidden(true)']:
            self.assertIn(item,s)
        self.assertNotIn('TimelineView',s)
        self.assertNotIn('.mask {',s)
        self.assertIn('guard running else { stop(); return }',r)
        self.assertIn('presentation.reset()',r)
        self.assertIn('motion.settle()',r)
        for fake in ['dynamicKick','dynamicBass','player.progress']:
            self.assertNotIn(fake,s+r)
        m=(ROOT/'Sonivo/BeatWaveMotion.swift').read_text()
        self.assertIn('first.capturedAt<=cutoff',m)
        self.assertIn('queue.count>90',m)
        self.assertIn('sqrt(130-decay*decay)',m)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift toolchain available in macOS CI')
    def test_compiled_swift_physics_detector_and_causal_queue(self):
        main=r'''
import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
var detector=BeatWaveKickDetector()
var frame=BeatWaveAudioFrame(capturedAt: 1,subBass: 0.9,bass: 0.8,rms: 0.7)
detector.process(frame)
check(detector.eventID==1,"First real onset must not be suppressed")
for i in 1...150 { frame.capturedAt=1+Double(i)/60; detector.process(frame) }
check(detector.eventID==1,"Sustained bass must not create invented beats")
detector.reset(); frame.capturedAt=4; detector.process(frame)
check(detector.eventID==2,"IDs must remain monotonic across seek")
var silence=BeatWaveKickDetector()
for i in 0..<300 { silence.process(BeatWaveAudioFrame(capturedAt: Double(i)/60)) }
check(silence.eventID==0,"Silence creates no kicks")
var referenceX: Float=0
for fps in [10,20,30,60,120] {
    var motion=MusicWaveMotion()
    var impulse=BeatWaveAudioFrame(capturedAt: 1,kickEnvelope: 1,kickEventID: 1,kickConfidence: 1)
    var elapsed: Float=0
    for _ in 0..<fps {
        motion.advance(delta: 1/Float(fps),frame: impulse,hasFreshAudio: true)
        impulse.kickEnvelope=0
        elapsed+=1/Float(fps)
        check(motion.springPosition.isFinite && abs(motion.springPosition)<0.2,"Spring unstable")
    }
    if fps==10 { referenceX=motion.springPosition }
    check(abs(motion.springPosition-referenceX)<0.0001,"Spring depends on FPS")
    for _ in 0..<fps*2 { motion.advance(delta: 1/Float(fps),frame: BeatWaveAudioFrame(),hasFreshAudio: false) }
    check(motion.springPosition==0 && motion.speed==0,"Pause must settle")
}
var once=MusicWaveMotion()
let kick=BeatWaveAudioFrame(kickEventID: 1,kickConfidence: 1)
check(once.advance(delta: 1/60,frame: kick,hasFreshAudio: true),"First impulse missing")
check(!once.advance(delta: 1/60,frame: kick,hasFreshAudio: true),"Duplicate impulse")
once.settle(); check(once.springVelocity==0,"Settle clears velocity")
var bad=BeatWaveAudioFrame(); bad.subBass = .nan; bad.bass = .infinity; bad.rms = -.infinity
once.advance(delta: 0.1,frame: bad,hasFreshAudio: true)
check(once.phase.isFinite && once.energy.isFinite,"Invalid features escaped sanitizing")
var queue=BeatWavePresentation()
queue.push(BeatWaveAudioFrame(capturedAt: 1,kickEventID: 3))
check(queue.sample(now: 1.05,estimatedOutputDelay: 0.1).kickEventID==0,"Queue returned future event")
check(queue.sample(now: 1.11,estimatedOutputDelay: 0.1).kickEventID==3,"Due event not presented")
queue.reset(); check(queue.sample(now: 2,estimatedOutputDelay: 0).kickEventID==0,"Reset leaked previous track")
print("Beat Waves Swift physics and presentation checks passed")
'''
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d); (p/'main.swift').write_text(main)
            compiled=subprocess.run(['swiftc','-swift-version','6',str(ROOT/'Sonivo/BeatWaveMotion.swift'),str(p/'main.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            checked=subprocess.run([str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(checked.returncode,0,checked.stdout+checked.stderr)

if __name__=='__main__': unittest.main()
