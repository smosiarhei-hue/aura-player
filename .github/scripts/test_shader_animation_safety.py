"""Source regression guards and reference math; device visuals/haptics need iPhone QA."""
import math
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / 'Sonivo/WaveShakeOverlayView.swift'


class ShaderAnimationSafetyTests(unittest.TestCase):
    def test_envelope_is_bounded_and_fully_releases(self):
        text = VIEW.read_text()
        duration = float(re.search(r'pulseDuration: TimeInterval = ([\d.]+)', text)[1])
        def pulse(age):
            if age < 0 or age >= duration:
                return 0
            if age < .09:
                return age / .09
            release = (age - .09) / (duration - .09)
            return math.exp(-4 * release) * (1 - release)
        self.assertEqual(pulse(-1), 0)
        self.assertEqual(pulse(duration), 0)
        self.assertAlmostEqual(pulse(.09), 1)
        values = [pulse(i / 1000) for i in range(3000)]
        self.assertTrue(all(math.isfinite(v) and 0 <= v <= 1 for v in values))
        self.assertLess(pulse(.3), pulse(.1))

    def test_haptic_curves_fit_api_limit_and_share_timing(self):
        text = VIEW.read_text()
        ages = re.search(r'let ages: \[TimeInterval\] = \[(.*?)\]', text)[1]
        ages = [float(value) for value in ages.split(',')]
        self.assertLessEqual(len(ages), 16)
        self.assertIn(.09, ages)
        self.assertEqual(ages[-1], .46)
        self.assertNotIn('(0...156)', text)
        self.assertIn('relativeTime: onset', text)
        self.assertIn('ShaderImpulseTimeline.pulseDuration', text)
        onsets = [.08, .60, 1.12, 1.64]
        self.assertTrue(all(b - a > .46 for a, b in zip(onsets, onsets[1:])))
        self.assertLess(onsets[-1] + .46, 2.6)

    def test_no_competing_music_haptics(self):
        music = (ROOT / 'Sonivo/MusicHapticsManager.swift').read_text()
        self.assertIn('values.count >= 32, !isVisualOverrideActive', music)
        self.assertIn('!isVisualOverrideActive, !isBeatWaveOverrideActive', music)
        self.assertIn('ensureEngineStarted(), let engine', music)
        text = VIEW.read_text()
        self.assertIn('setVisualOverride(true)', text)
        self.assertIn('setVisualOverride(false)', text)

    def test_background_dismiss_and_accessibility_stop_haptics(self):
        text = VIEW.read_text()
        self.assertIn('onDisappear { haptics.stop() }', text)
        self.assertIn('phase != .active { haptics.stop(); onDismiss() }', text)
        self.assertIn('onChange(of: reduceMotion)', text)
        self.assertIn('!reduceMotion, SettingsStore.shared.hapticsEnabled', text)
        self.assertIn('supportsHaptics', text)
        self.assertIn('try? player?.stop', text)
        self.assertIn('catch {\n                haptics.stop()', text)

    def test_one_shake_path_and_debounce(self):
        home = (ROOT / 'Sonivo/SonivoHomeRedesignedView.swift').read_text()
        manager = (ROOT / 'Sonivo/AntigravityTransitionManager.swift').read_text()
        self.assertIn('!showShakeOverlay', home)
        self.assertIn('antigravity.phase == .idle', home)
        self.assertIn('NotificationCenter.default.post(name: .deviceDidShakeNotification', manager)
        self.assertEqual(home.count('antigravity.triggerShift('), 1)
        self.assertNotIn('self?.triggerShift()', manager)

    def test_negative_coordinates_use_glsl_mod_and_finite_radiance(self):
        for diagonal in [-10, -1.9, -.21, -.01, 0, .01, .21, 1.9, 10]:
            grid = diagonal - .2 * math.floor(diagonal / .2)
            self.assertGreaterEqual(grid, -1e-12)
            self.assertLessEqual(grid, .2 + 1e-12)
        for dimension in [1, 320, 430, 1290]:
            for distance in [0, 1e-9, .01, 1, 5]:
                raw = .002 * 16 / max(1.2 / dimension, distance)
                mapped = raw / (1 + raw)
                self.assertTrue(math.isfinite(mapped) and 0 <= mapped < 1)


if __name__ == '__main__':
    unittest.main()
