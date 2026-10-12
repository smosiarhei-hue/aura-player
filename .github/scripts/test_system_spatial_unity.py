"""Source guards plus real Swift envelope/fader/curve execution on the macOS builder."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
class SystemSpatialUnityTests(unittest.TestCase):
    def test_only_system_spatialization_and_no_fake_rendering_status(self):
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        ui=(ROOT/'Sonivo/PlayerScreenV2.swift').read_text()
        session=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/PlaybackAudioSessionSetup.swift').read_text()
        self.assertIn('.monoStereoAndMultichannel',core)
        self.assertIn('setSupportsMultichannelContent(true)',session)
        self.assertIn('mode: .default',session)
        self.assertNotIn('isSpatialPlaybackActive',core)
        self.assertNotIn('isDolbyAtmosActive',core+ui)
        self.assertNotIn('isTrueDolbyAtmos',ui)
        self.assertNotIn('codec.contains("atmos")',ui)
        self.assertIn('режим выбирает iOS',core)
        for name in ['reverbA','reverbB','looperReverb','configureReverb','applyReverbPreset']:
            self.assertNotIn(name,core)
        for eq in ['eqNodeA','eqNodeB','looperEQ']:
            self.assertIn(f'engine.connect({eq}, to: engine.mainMixerNode, format: nil)',core)
    def test_old_room_plans_cannot_add_synthetic_spatial_reverb(self):
        planner=(ROOT/'Packages/AutoMixV2/Sources/MixPlanner/MixPlanner.swift').read_text()
        engine=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift').read_text()
        self.assertNotIn('planSpaceReverb',planner)
        self.assertNotIn('kind: .reverbWash',planner)
        handler=engine.split('case .reverbWash:',1)[1].split('case .volume:',1)[0]
        self.assertIn('slot.fxDelay.wetDryMix = 0',handler)
        self.assertNotIn('feedback =',handler)
        self.assertNotIn('delayTime =',handler)
    def test_unity_output_and_no_double_vocal_processing(self):
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        bridge=(ROOT/'Sonivo/AutoMixV2AppBridge.swift').read_text()
        self.assertIn('var volume: Float { playbackGainState.gain }',core)
        self.assertNotIn('streamHeadroomCeiling',core)
        self.assertIn('engine.mainMixerNode.outputVolume = volume',core)
        self.assertIn('activeStreamingPlayer.volume = outgoing * volume',core)
        self.assertIn('idleStreamingPlayer.volume = incomingIsStream ? incoming * volume : 0',core)
        self.assertNotIn('VocalIsolationManager.processBuffer(buffer)',bridge)
        self.assertIn('VocalIsolationManager.shared.attach(to: engine.userEQUnit)',bridge)
        self.assertIn('loudnessNormalization: false',(ROOT/'Sonivo/AutoMixV2AnalysisRuntime.swift').read_text())
        self.assertIn('loudnessNormalization: Bool = false',(ROOT/'Packages/AutoMixV2/Sources/MixModels/MixSettings.swift').read_text())
    def test_no_captured_attenuated_volume_is_restored(self):
        f=(ROOT/'Sonivo/AntigravityTransitionManager.swift').read_text()
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertNotIn('initialVolume',f+core)
        self.assertIn('activeRequestID == identity',f)
        self.assertIn('endPlaybackFade(.wave, id: gainID)',f)
        self.assertIn('endPlaybackFade(.sleep, id: gainID)',core)
        self.assertIn('CrossfadeCurve.gains(progress: p)',core)
    @unittest.skipUnless(shutil.which('swiftc'),'Native Swift checks run on macOS CI')
    def test_actual_envelopes_and_production_wave_fader(self):
        f=(ROOT/'Sonivo/AntigravityTransitionManager.swift').read_text()
        fader=f[f.index('@MainActor\nfinal class AntigravityAudioFader'):f.index('// MARK: - 4.')]
        fixture=r'''
import Foundation
@MainActor final class PlayerCore {
 static let shared = PlayerCore()
 var isPlaying = true
 var playbackRequestID = 0
 var state = PlaybackGainState()
 var volume: Float { state.gain }
 func beginPlaybackFade(_ scope: PlaybackGainState.Scope) -> UUID { state.begin(scope) }
 @discardableResult func setPlaybackFade(_ scope: PlaybackGainState.Scope, id: UUID, gain: Float) -> Bool { state.update(scope,id:id,gain:gain) }
 func endPlaybackFade(_ scope: PlaybackGainState.Scope,id:UUID) { state.end(scope,id:id) }
 func switchTrack() { playbackRequestID += 1; state.reset(.wave) }
}
FADER
@main struct Checks {
 @MainActor static func main() async throws {
  var s = PlaybackGainState()
  precondition(s.gain == 1)
  let wave = s.begin(.wave); precondition(s.update(.wave,id:wave,gain:0.5))
  let sleep = s.begin(.sleep); precondition(s.update(.sleep,id:sleep,gain:0.25))
  precondition(s.gain == 0.125)
  precondition(s.end(.wave,id:wave) && s.gain == 0.25)
  let newer = s.begin(.sleep); s.update(.sleep,id:newer,gain:0.4)
  precondition(!s.end(.sleep,id:sleep) && !s.update(.sleep,id:sleep,gain:1))
  precondition(s.gain == 0.4)
  precondition(!s.update(.sleep,id:newer,gain:.nan) && s.gain == 0.4)
  s.update(.sleep,id:newer,gain:-1); precondition(s.gain == 0)
  s.update(.sleep,id:newer,gain:9); precondition(s.gain == 1)
  s.resetAll(); precondition(s.gain == 1)
  precondition(!MixSettings().loudnessNormalization)
  for progress in stride(from:0.0,through:1.0,by:0.001) {
   let pair = CrossfadeCurve.gains(progress:progress)
   precondition(abs(pair.outgoing*pair.outgoing + pair.incoming*pair.incoming - 1) < 0.00001)
  }
  let player = PlayerCore.shared
  let sleepID = player.beginPlaybackFade(.sleep)
  player.setPlaybackFade(.sleep,id:sleepID,gain:0.25)
  var switches = 0
  await AntigravityAudioFader.shared.performCrossfade { switches += 1; player.switchTrack() }
  precondition(switches == 1 && player.volume == 0.25,"Wave fade must not inherit or restore an attenuated sleep level")
  player.endPlaybackFade(.sleep,id:sleepID); precondition(player.volume == 1)
  let cancelled = Task { @MainActor in await AntigravityAudioFader.shared.performCrossfade { fatalError("Cancelled fader switched track") } }
  try await Task.sleep(for:.milliseconds(60)); cancelled.cancel(); await cancelled.value
  precondition(player.volume == 1)
  // A newer fade started while the old onSwitch awaited must retain ownership.
  var entered = false, release = false
  let old = Task { @MainActor in await AntigravityAudioFader.shared.performCrossfade {
   entered = true
   while !release { try? await Task.sleep(for:.milliseconds(5)) }
  } }
  while !entered { try await Task.sleep(for:.milliseconds(5)) }
  let fresh = Task { @MainActor in await AntigravityAudioFader.shared.performCrossfade { player.switchTrack() } }
  try await Task.sleep(for:.milliseconds(50)); release = true; await old.value
  precondition(player.volume < 0.99,"Old completion unmuted the newer fade")
  await fresh.value; precondition(player.volume == 1)
  print("Actual unity/scoped gain, cancellation, overlap, sleep coexistence and equal-power checks passed")
 }
}
'''.replace('FADER',fader)
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'Checks.swift').write_text(fixture)
            sources=[ROOT/'Sonivo/PlaybackGainState.swift',ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/CrossfadeCurve.swift',ROOT/'Packages/AutoMixV2/Sources/MixModels/MixSettings.swift',p/'Checks.swift']
            build=subprocess.run(['swiftc','-swift-version','6',*map(str,sources),'-o',str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stderr)
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=12)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
