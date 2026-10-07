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

    def test_apple_explicit_draw_lifecycle_and_late_drawable(self):
        s=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('view.delegate=context.coordinator',s)
        self.assertIn('NSObject, @preconcurrency MTKViewDelegate',s)
        self.assertIn('func draw(in view: MTKView)',s)
        tick=s.split('fileprivate func tick(',1)[1].split('func draw(in view:',1)[0]
        self.assertIn('autoreleasepool { view.draw() }',tick)
        self.assertNotIn('render(view)',tick)
        self.assertNotIn('currentDrawable',tick)
        delegate=s.split('func draw(in view:',1)[1].split('private func updateStrands()',1)[0]
        self.assertIn('autoreleasepool { render(view) }',delegate)
        render=s.split('private func render(',1)[1].split('private static func makeNoise',1)[0]
        self.assertLess(render.index('updateStrands()'),render.index('view.currentRenderPassDescriptor'))
        self.assertLess(render.index('var uniforms='),render.index('view.currentRenderPassDescriptor'))
        self.assertLess(render.index('view.currentRenderPassDescriptor'),render.index('view.currentDrawable'))
        self.assertIn('view.delegate=nil',s)
        self.assertIn('buffer.status == .error',s)
        self.assertNotIn('waitUntilCompleted',s)
        self.assertNotIn('waitUntilScheduled',s)

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

    def test_shared_noise_budget_and_direct_geometric_punch(self):
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        strand=m.split('float3 neuralStrand(',1)[1].split('float3 neuralWeave(',1)[0]
        self.assertNotIn('turbulence(',strand)
        field=m.split('float4 evalNeuralFloat(',1)[1].split('fragment float4',1)[0]
        self.assertEqual(field.count('turbulence('),1)
        self.assertIn('p /= 1.0+radialPush',field)
        self.assertIn('springImpulse*0.22*sin',field)
        self.assertIn('float t = uPhase;',field)
        r=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('let t=Float(motion.phase)',r)
        self.assertNotIn('let t=Float(motion.phase)*0.6',r)
        self.assertIn('diagnosticSubmissions',r)
        self.assertIn('diagnosticBusyDrops',r)
        self.assertIn('tag: "BEAT_WAVE"',r)
        self.assertIn('routeDelayMs',r)

    def test_occupied_fft_bins_drive_all_five_features(self):
        s=(ROOT/'Sonivo/spectrumanalyzer.swift').read_text()
        for name in ['subBass','bass','lowMids','mids','highs']:
            self.assertIn('beatFrame.'+name+' = BeatWaveBandEnergy.mean(values: values,counts: counts',s)
        self.assertNotIn('beatFrame.subBass = values[0..<4].reduce',s)

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
// Native 1024 FFT has holes in the lowest logarithmic bands. Verify both common rates.
for sampleRate in [44100.0,48000.0] {
    var counts=[Int](repeating: 0,count: 32)
    var values=[Float](repeating: 0,count: 32)
    for bin in 1..<512 {
        let frequency=Double(bin)*sampleRate/1024
        if frequency>=30 && frequency<=16000 {
            let band=min(31,max(0,Int(log2(frequency/30)/log2(16000/30)*32)))
            counts[band]+=1; values[band]=0.8
        }
    }
    check(abs(BeatWaveBandEnergy.mean(values: values,counts: counts,range: 0..<4)-0.8)<0.00001,"Empty sub slots attenuated signal")
    check(abs(BeatWaveBandEnergy.mean(values: values,counts: counts,range: 4..<9)-0.8)<0.00001,"Empty bass slots attenuated signal")
}
check(abs(BeatWaveBandEnergy.mean(values: [1,0.25],counts: [1,3],range: 0..<2)-0.4375)<0.00001,"Mean must weight populated bins")
check(BeatWaveBandEnergy.mean(values: [.nan],counts: [1],range: 0..<1)==0,"Invalid spectrum must stay finite")
check(BeatWaveBandEnergy.mean(values: [1],counts: [0],range: 0..<1)==0,"Empty spectrum is silence")
var punch=MusicWaveMotion()
let punchFrame=BeatWaveAudioFrame(subBass: 0.8,bass: 0.7,mids: 0.4,rms: 0.6,kickEnvelope: 1,kickEventID: 1,kickConfidence: 0.8)
check(punch.advance(delta: 1/120,frame: punchFrame,hasFreshAudio: true),"Kick event missing")
check(punch.impact>=0.8,"One-shot punch delayed by smoothing")
let radialPush=min(Float(0.24),max(Float(-0.12),punch.impact*0.08+punch.springPosition*1.8))
check(radialPush>0.06,"First presented frame must visibly deform")
var running=MusicWaveMotion()
let steady=BeatWaveAudioFrame(subBass: 0.8,bass: 0.7,mids: 0.4,rms: 0.6)
for _ in 0..<240 { running.advance(delta: 1/120,frame: steady,hasFreshAudio: true) }
check(running.speed>1.0 && running.phase>1.5,"Flow still uses the excessively slow preset")
var previousPhase=running.phase
for i in 0..<60 {
    let delta: Float = i%7==0 ? 0.1 : 1/120
    running.advance(delta: delta,frame: BeatWaveAudioFrame(),hasFreshAudio: false)
    check(running.phase>=previousPhase && running.phase.isFinite,"Frame hitch caused phase jump or reversal")
    previousPhase=running.phase
}
print("Beat Waves Swift physics and presentation checks passed")
'''
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d); (p/'main.swift').write_text(main)
            compiled=subprocess.run(['swiftc','-swift-version','6',str(ROOT/'Sonivo/BeatWaveMotion.swift'),str(p/'main.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            checked=subprocess.run([str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(checked.returncode,0,checked.stdout+checked.stderr)

if __name__=='__main__': unittest.main()
