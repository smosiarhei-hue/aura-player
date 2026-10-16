"""Actual AVAudioUnitEQ offline rendering on macOS; portable signal tests run everywhere."""
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]

class NativeEQTests(unittest.TestCase):
    def test_categories_preserve_ten_real_bands_and_route_policy(self):
        ui=(ROOT/'Sonivo/playerchrome.swift').read_text()
        self.assertIn('EQFrequencyRegion.allCases',ui)
        self.assertIn('EQFrequencyRegion.bandTitles',ui)
        self.assertNotIn('Защита EQ от перегрузки отключена',ui)
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertIn('node.inputFormat(forBus: 0).sampleRate',core)
        for runtime in ['NeuroMixRuntime','AutoMixV2Runtime']:
            self.assertIn(runtime+'.existing?.applyUserEQ(gains: user, enabled: on)',core)
        bridge=(ROOT/'Sonivo/AutoMixV2AppBridge.swift').read_text()
        self.assertGreaterEqual(bridge.count('enabled: PlayerCore.shared.shouldApplyUserEQ'),2)
        dual=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift').read_text()
        for value in ['eqGeneration == generation','kAudioUnitSubType_PeakLimiter','EQHeadroom.preamp','eqLimiter.bypass = !active']:
            self.assertIn(value,dual)

    @unittest.skipUnless(platform.system()=='Darwin' and shutil.which('swiftc'), 'Native AVFAudio requires macOS')
    def test_native_filter_response_and_headroom_execute(self):
        fixture=r'''
import Foundation
import AVFAudio
import AudioToolbox
@main struct Checks {
    static func render(gains: [Float], hz: Double, amplitude: Float, enabled: Bool = true) throws -> [Float] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 10)
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        for node in [player as AVAudioNode, eq, limiter] { engine.attach(node) }
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        let frequencies: [Float] = [40,60,120,250,500,1000,2000,4000,8000,15000]
        for (i, band) in eq.bands.enumerated() {
            band.frequency=frequencies[i]; band.bandwidth=1; band.gain=gains[i]; band.bypass=false
            band.filterType = i == 0 ? .lowShelf : (i == 9 ? .highShelf : .parametric)
        }
        eq.globalGain=EQHeadroom.preamp(gains:gains,sampleRate:48000)
        eq.bypass = !enabled
        limiter.bypass = !enabled || !gains.contains { $0 != 0 }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let input=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        input.frameLength=48000
        for n in 0..<48000 {
            let x=amplitude*Float(sin(2*Double.pi*hz*Double(n)/48000))
            input.floatChannelData![0][n]=x;input.floatChannelData![1][n]=x*0.25
        }
        player.scheduleBuffer(input)
        try engine.start();player.play()
        defer { player.stop();engine.stop() }
        let out=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024)!
        var samples=[Float](), attempts=0
        while samples.count < 48000 {
            attempts += 1;precondition(attempts < 200, "Offline render did not advance")
            let frames=AVAudioFrameCount(min(1024,48000-samples.count))
            let status=try engine.renderOffline(frames,to:out)
            guard status == .success else { continue }
            for n in 0..<Int(out.frameLength) {
                let l=out.floatChannelData![0][n], r=out.floatChannelData![1][n]
                precondition(l.isFinite && r.isFinite)
                precondition(abs(r-l*0.25)<0.005, "Stereo image changed")
                samples.append(l)
            }
        }
        return samples
    }
    static func main() throws {
        let flat=[Float](repeating:0,count:10)
        precondition(EQHeadroom.preamp(gains:flat,sampleRate:48000)==0)
        precondition(EQHeadroom.preamp(gains:[Float](repeating:-12,count:10),sampleRate:48000)==0)
        var curve=flat;curve[5]=6
        let output=try render(gains:curve,hz:1000,amplitude:0.01)
        let rms=sqrt(output.suffix(24000).reduce(0.0) { $0+Double($1)*Double($1) }/24000)
        let db=20*log10(rms/(0.01/sqrt(2)))
        precondition(abs(db - Double(6+EQHeadroom.preamp(gains:curve,sampleRate:48000))) < 0.6, "Native center gain incorrect: \(db)")
        for rate in [8000.0,32000,44100,48000,96000] {
            let pre=EQHeadroom.preamp(gains:[Float](repeating:12,count:10),sampleRate:rate)
            precondition(pre.isFinite && pre == 0)
        }
        let hot=try render(gains:[Float](repeating:12,count:10),hz:60,amplitude:0.95)
        precondition(hot.allSatisfy { abs($0) <= 1.01 },"Native output overflow")
        print("native EQ response, stereo and sample-peak checks passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'Checks.swift').write_text(fixture)
            cmd=['swiftc','-swift-version','6','-O','-parse-as-library',str(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/EQHeadroom.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')]
            build=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
            self.assertEqual(build.returncode,0,build.stderr[-12000:])
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=120)
            self.assertEqual(run.returncode,0,(run.stdout+run.stderr)[-12000:])
