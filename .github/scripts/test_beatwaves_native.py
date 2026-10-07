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
        self.assertNotIn('packetPhase',m)
        self.assertNotIn('atan2',m)
        self.assertIn('uLowEnergy*0.55+uImpact*0.65',m)
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
        self.assertIn('let decay: Float = 8',m)
        self.assertIn('(x+coefficient*dt)*attenuation',m)

    def test_shared_noise_budget_and_direct_geometric_punch(self):
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        strand=m.split('float3 neuralStrand(',1)[1].split('float3 neuralWeave(',1)[0]
        self.assertNotIn('turbulence(',strand)
        field=m.split('float4 evalNeuralFloat(',1)[1].split('fragment float4',1)[0]
        self.assertEqual(field.count('turbulence('),1)
        self.assertNotIn('radialPush',field)
        self.assertNotIn('swirl',field)
        self.assertIn('uSpringDeform*0.8',strand)
        self.assertIn('float t = uPhase;',field)
        r=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('let count: Float=12',r)
        self.assertIn('let angle=id*(2*Float.pi)',r)
        self.assertNotIn('t*0.12',r)
        self.assertNotIn('let t=Float(motion.phase)*0.6',r)
        self.assertIn('diagnosticSubmissions',r)
        self.assertIn('diagnosticBusyDrops',r)
        self.assertIn('tag: "BEAT_WAVE"',r)
        self.assertIn('routeDelayMs',r)

    def test_top_extension_preserves_hero_lower_boundary(self):
        h=(ROOT/'Sonivo/SonivoHomeRedesignedView.swift').read_text()
        wave=h.split('private var waveHero:',1)[1].split('private var quickDestinations:',1)[0]
        self.assertIn('geometry.safeAreaInsets.top',h)
        self.assertIn('.scrollClipDisabled()',h)
        self.assertIn('height: hero.size.height+waveTopInset',wave)
        self.assertIn('.offset(y: -waveTopInset)',wave)
        self.assertEqual(wave.count('MusicWaveBackground('),1)
        self.assertEqual(wave.count('.clipped()'),1)
        self.assertNotIn('UIScreen.main',h)

    def test_metal_top_uv_is_one_and_lower_feather_is_preserved(self):
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        self.assertIn('(p+1)*0.5',m)
        self.assertIn('float fYTop = 0.015',m)
        self.assertIn('float fYBot = max(0.03, 0.12 * uEdgeFeather)',m)
        self.assertIn('smoothstep(0.0, fYBot, uvSample.y)',m)
        self.assertIn('smoothstep(1.0 - fYTop, 1.0, uvSample.y)',m)

    def test_neural_float_is_paired_weave_not_parallel_lanes(self):
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        for item in ['spineCore','spineInner','spineHalo','float3 reach=abs','float gate=smoothstep',
                     'neuralStrand(p,direction.y,-direction.x']:
            self.assertIn(item,m)
        self.assertNotIn('float lane=',m)
        self.assertNotIn('q.y -= lane',m)
        self.assertNotIn('packetPhase',m)
        self.assertNotIn('t * uSwirl',m)

    def test_artwork_palette_reaches_uniforms_and_stale_cover_cannot_win(self):
        w=(ROOT/'Sonivo/MusicWaveBackground.swift').read_text()
        self.assertIn('BeatWaveMetalView(colors: resolvedColors',w)
        self.assertIn('.task(id: coverKey)',w)
        self.assertIn('!Task.isCancelled,coverKey==key',w)
        self.assertIn('resolvedCoverKey==coverKey',w)
        p=(ROOT/'Sonivo/BeatWaveArtworkPalette.swift').read_text()
        for item in ['LibraryStore.cachedArtworkImage','Task.detached(priority: .utility)',
                     'while order.count>32','CGColorSpace.sRGB','data.count<=12_000_000']:
            self.assertIn(item,p)
        self.assertNotIn('track.url',p)
        self.assertNotIn('AVPlayer',p)
        r=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        self.assertIn('setPalette(colors)',r)
        self.assertIn('1-exp(-dt/0.85)',r)
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        self.assertIn('#define uColorA u.colorA.rgb',m)
        self.assertNotIn('float3(0.58,0.20,0.95)',m)

    def test_true_edr_float_output_and_hardware_sdr_fallback(self):
        r=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
        for item in ['.rgba16Float','CGColorSpace.extendedLinearDisplayP3',
                     'wantsExtendedDynamicRangeContent=desired',
                     'potentialEDRHeadroom','currentEDRHeadroom','hdrPipeline != nil',
                     'view.window?.windowScene?.screen']:
            self.assertIn(item,r)
        self.assertIn('desired ? .rgba16Float : .bgra8Unorm',r)
        self.assertIn('!lowPower && potential.isFinite',r)
        m=(ROOT/'Sonivo/BeatWave.metal').read_text()
        self.assertIn('rgb=linearP3(rgb)*gain',m)
        self.assertIn('rgb=clamp(rgb,0.0,max(1.0,u.display.x))',m)
        self.assertNotIn('Dolby Vision',m)
        # CPU/GPU SIMD4 uniform ABI must match, including cover and display channels.
        cpu=r.split('private struct Uniforms {',1)[1].split('}',1)[0]
        gpu=m.split('struct BeatWaveUniforms {',1)[1].split('}',1)[0]
        names=['resolution','motion','surface','colorA','colorB','colorC','display']
        self.assertEqual([line.split('var ')[1].split(':')[0] for line in cpu.splitlines() if 'var ' in line],names)
        self.assertEqual([line.split('float4 ')[1].split(';')[0] for line in gpu.splitlines() if 'float4 ' in line],names)

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
    var impulse=BeatWaveAudioFrame(capturedAt: 1,rms: 0.8,kickEnvelope: 1,kickEventID: 1,kickConfidence: 1)
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
let kick=BeatWaveAudioFrame(rms: 0.8,kickEventID: 1,kickConfidence: 1)
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
check(punch.impact>0.2 && punch.impact<0.8,"Kick must have soft, short attack")
check(punch.springPosition>0,"Measured onset must deform immediately")
for _ in 0..<5 { punch.advance(delta: 1/120,frame: punchFrame,hasFreshAudio: true) }
check(punch.impact>0.65,"Soft attack must not obscure the kick")
var running=MusicWaveMotion()
let steady=BeatWaveAudioFrame(subBass: 0.8,bass: 0.7,mids: 0.4,rms: 0.6)
for _ in 0..<240 { running.advance(delta: 1/120,frame: steady,hasFreshAudio: true) }
check(running.speed>0.05 && running.speed<=0.18 && running.phase<0.36,"Slow flow speed cap violated")
var previousPhase=running.phase
for i in 0..<60 {
    let delta: Float = i%7==0 ? 0.1 : 1/120
    running.advance(delta: delta,frame: BeatWaveAudioFrame(),hasFreshAudio: false)
    check(running.phase>=previousPhase && running.phase.isFinite,"Frame hitch caused phase jump or reversal")
    previousPhase=running.phase
}
// Silent PCM with a stale/nonzero logarithmic spectrum cannot generate motion or haptics.
var gated=MusicWaveMotion()
let fake=BeatWaveAudioFrame(subBass: 1,bass: 1,mids: 1,highs: 1,kickEnvelope: 1,kickEventID: 12,kickConfidence: 1)
for _ in 0..<240 {
    check(!gated.advance(delta: 1/120,frame: fake,hasFreshAudio: true),"Silent PCM invented a kick")
}
check(gated.phase==0 && gated.energy==0 && gated.lowEnergy==0 && gated.impact==0,"Silent spectrum moved the field")
// Genuine separated low-frequency onsets, not sustained bass or high-only percussion.
var kicks=BeatWaveKickDetector()
var highOnly=BeatWaveKickDetector()
for i in 0..<200 {
    let on=i%20==0
    let stamp=Double(i)*0.025+10
    kicks.process(BeatWaveAudioFrame(capturedAt: stamp,subBass: on ? 0.8 : 0.1,bass: on ? 0.7 : 0.1,rms: on ? 0.5 : 0.06))
    highOnly.process(BeatWaveAudioFrame(capturedAt: stamp,highs: on ? 1 : 0,rms: on ? 0.5 : 0))
}
check(kicks.eventID==10,"Real kick cadence lost or duplicated")
check(highOnly.eventID==0,"High-only sound created bass impulses")
// Critical response decays to rest without a negative bounce/secondary tick.
var recoil=MusicWaveMotion()
recoil.advance(delta: 1/120,frame: kick,hasFreshAudio: true)
for _ in 0..<480 {
    recoil.advance(delta: 1/120,frame: BeatWaveAudioFrame(),hasFreshAudio: false)
    check(recoil.springPosition>=0,"Recoil bounced through zero")
}
check(recoil.springPosition==0,"Critical recoil did not settle")
// Actual cover colors survive extraction; neutral art never becomes arbitrary red/purple.
func pixels(_ rgb: (UInt8,UInt8,UInt8),_ count: Int) -> [UInt8] {
    (0..<count).flatMap { _ in [rgb.0,rgb.1,rgb.2,UInt8(255)] }
}
let red=BeatWavePaletteMath.dominantRGB(rgba: pixels((240,20,15),64))
let blue=BeatWavePaletteMath.dominantRGB(rgba: pixels((10,30,240),64))
check(red.count==1 && red[0].x>red[0].z*5,"Red cover lost its hue")
check(blue.count==1 && blue[0].z>blue[0].x*5,"Blue cover lost its hue")
let neutral=BeatWavePaletteMath.dominantRGB(rgba: pixels((90,90,90),64)+pixels((0,0,0),64))
check(neutral.allSatisfy { abs($0.x-$0.y)<0.0001 && abs($0.y-$0.z)<0.0001 },"Monochrome art invented a hue")
check(BeatWavePaletteMath.dominantRGB(rgba: [1,2,3]).isEmpty,"Malformed pixels accepted")
check(BeatWavePaletteMath.dominantRGB(rgba: [255,0,0,0]).isEmpty,"Transparent padding tinted the field")
let accented=BeatWavePaletteMath.dominantRGB(rgba: pixels((255,255,255),128)+pixels((10,30,240),32))
check(accented[0].z>accented[0].x*5,"White margins hid the artwork accent")
check(BeatWavePaletteMath.safeHeadroom(potential: 4,current: 3,lowPower: false)==2.5,"HDR safety cap lost")
check(BeatWavePaletteMath.safeHeadroom(potential: 4,current: 1,lowPower: false)==1,"Invented unavailable headroom")
check(BeatWavePaletteMath.safeHeadroom(potential: 4,current: 3,lowPower: true)==1,"Low-power mode enabled HDR")
check(BeatWavePaletteMath.safeHeadroom(potential: .nan,current: .infinity,lowPower: false)==1,"Invalid headroom escaped")
print("Beat Waves Swift physics and presentation checks passed")
'''
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d); (p/'main.swift').write_text(main)
            compiled=subprocess.run(['swiftc','-swift-version','6',str(ROOT/'Sonivo/BeatWaveMotion.swift'),str(ROOT/'Sonivo/BeatWavePaletteMath.swift'),str(p/'main.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            checked=subprocess.run([str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(checked.returncode,0,checked.stdout+checked.stderr)

if __name__=='__main__': unittest.main()
