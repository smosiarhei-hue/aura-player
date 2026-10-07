"""Source regression guards; device volume behavior is validated on iOS, not Linux."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCREEN = (ROOT / 'Sonivo/PlayerScreenV2.swift').read_text()
CORE = (ROOT / 'Sonivo/playercore.swift').read_text()
MANAGER = SCREEN.split('final class SystemVolumeManager {', 1)[1].split('final class SystemVolumeHostView:', 1)[0]
HOST = SCREEN.split('final class SystemVolumeHostView:', 1)[1].split('struct FluidVolumeSlider:', 1)[0]
UI = SCREEN.split('struct FluidVolumeSlider:', 1)[1].split('struct VideoShotPlayerView:', 1)[0]

class SystemVolumeSyncTests(unittest.TestCase):
    def test_initial_and_observed_value_come_from_phone(self):
        self.assertIn('private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume', MANAGER)
        self.assertIn('options: [.initial, .new]', MANAGER)
        self.assertIn('self?.refreshFromSystem()', MANAGER)
        self.assertIn('min(1, AVAudioSession.sharedInstance().outputVolume)', MANAGER)

    def test_system_slider_does_not_double_attenuate_player(self):
        self.assertNotRegex(MANAGER, r'PlayerCore\.shared\.volume\s*=')
        self.assertNotIn('let saved =', MANAGER)
        self.assertIn('slider.setValue(clamped, animated: false)', MANAGER)
        self.assertIn('slider.sendActions(for: .valueChanged)', MANAGER)

    def test_hardware_updates_are_not_suppressed(self):
        self.assertNotIn('isSettingInternal', MANAGER)
        self.assertNotIn('change.newValue', MANAGER)
        self.assertNotIn('dragVolume', UI)
        self.assertIn('let currentVol = volumeManager.volume', UI)

    def test_route_foreground_and_reset_refresh(self):
        for name in ['routeChangeNotification', 'mediaServicesWereResetNotification', 'didBecomeActiveNotification']:
            self.assertIn(name, MANAGER)
        self.assertIn('self.pendingVolume = nil', MANAGER)

    def test_invalid_values_are_rejected_and_zero_is_allowed(self):
        self.assertIn('guard newVolume.isFinite else { return }', MANAGER)
        self.assertIn('let clamped = max(0, min(1, newVolume))', MANAGER)
        self.assertNotIn('clamped > 0', MANAGER)

    def test_readback_is_versioned_not_a_write_loop(self):
        self.assertIn('self.requestGeneration == generation', MANAGER)
        delayed = MANAGER.split('DispatchQueue.main.asyncAfter', 1)[1]
        self.assertIn('self.refreshFromSystem()', delayed)
        self.assertNotIn('sendActions', delayed)

    def test_host_mounts_before_use_and_detaches_by_identity(self):
        self.assertIn('guard slider.window != nil', MANAGER)
        self.assertIn('guard systemSlider === slider else', MANAGER)
        self.assertIn('guard window != nil', HOST)
        self.assertIn('static func dismantleUIView', HOST)
        self.assertIn('uiView.detachVolumeSlider()', HOST)
        self.assertIn('volumeSlider(in: child)', HOST)

    def test_pending_request_is_applied_when_host_is_ready(self):
        self.assertIn('pendingVolume = clamped', MANAGER)
        self.assertIn('setVolume(pendingVolume)', MANAGER)
        self.assertIn('self.pendingVolume = nil', MANAGER)

    def test_no_stale_internal_volume_restore_or_fade_persistence(self):
        self.assertNotIn('defaults.float(forKey: "player.volume")', CORE)
        self.assertNotIn('defaults.set(volume, forKey: "player.volume")', CORE)
        self.assertIn('defaults.removeObject(forKey: "player.volume")', CORE)
        self.assertIn('volume = 1.0\n        engine.mainMixerNode.outputVolume = volume', CORE)
        # Transitions still have an independent internal gain and stream headroom.
        self.assertIn('streamingPlayer.volume = volume * Self.streamHeadroomCeiling', CORE)
        self.assertIn('engine.mainMixerNode.outputVolume = volume', CORE)

    def test_user_controls_cover_full_range_and_accessibility(self):
        self.assertEqual(UI.count('value.location.x / max(width, 1)'), 2)
        self.assertIn('volumeManager.volume + step', UI)
        self.assertIn('volumeManager.volume - step', UI)
        self.assertIn('.onAppear { volumeManager.refreshFromSystem() }', UI)

if __name__ == '__main__':
    unittest.main()
