# Path: .github/scripts/test_antigravity_spec.py
"""Tests for Antigravity transition module specifications and requirements."""

import unittest
from pathlib import Path


class AntigravitySpecTests(unittest.TestCase):
    def setUp(self):
        self.repo_root = Path(__file__).resolve().parent.parent.parent
        self.swift_manager = self.repo_root / "Aurora" / "AntigravityTransitionManager.swift"
        self.metal_shader = self.repo_root / "Aurora" / "AntigravityVortex.metal"
        self.hero_view = self.repo_root / "Aurora" / "MyWaveHeroView.swift"
        self.home_view = self.repo_root / "Aurora" / "AuraHomeRedesignedView.swift"

    def test_files_exist(self):
        self.assertTrue(self.swift_manager.exists(), "AntigravityTransitionManager.swift missing")
        self.assertTrue(self.metal_shader.exists(), "AntigravityVortex.metal missing")
        self.assertTrue(self.hero_view.exists(), "MyWaveHeroView.swift missing")
        self.assertTrue(self.home_view.exists(), "AuraHomeRedesignedView.swift missing")

    def test_motion_detector_parameters(self):
        content = self.swift_manager.read_text(encoding="utf-8")
        # Acceleration threshold >= 2.4g
        self.assertIn("totalAcceleration >= 2.4", content)
        # Window 180ms to 350ms
        self.assertIn("elapsedMs >= 180.0 && elapsedMs <= 350.0", content)
        # 120 Hz update rate
        self.assertIn("1.0 / 120.0", content)
        # Debounce 1.2s
        self.assertIn("1.2", content)

    def test_core_haptics_two_phase_pattern(self):
        content = self.swift_manager.read_text(encoding="utf-8")
        # Continuous ramp 0..120ms with 0.2 to 0.8
        self.assertIn("CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.2)", content)
        self.assertIn("CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)", content)
        self.assertIn("value: 0.8", content)
        # Transient click at 120ms with 1.0 and 0.9 sharpness
        self.assertIn("CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)", content)
        self.assertIn("CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)", content)

    def test_audio_crossfade_timing(self):
        content = self.swift_manager.read_text(encoding="utf-8")
        # 200ms fade-out and 300ms fade-in
        self.assertIn("fadeOutSteps = 8", content)
        self.assertIn("fadeInSteps = 12", content)
        self.assertIn("25_000_000", content)  # 25ms steps

    def test_metal_shader_signature_and_logic(self):
        content = self.metal_shader.read_text(encoding="utf-8")
        self.assertIn("[[ stitchable ]] half4 antigravityVortex", content)
        self.assertIn("vortexAngle", content)
        self.assertIn("distortionStrength", content)
        self.assertIn("colorShift", content)
        self.assertIn("neonAccent", content)

    def test_hero_view_3d_flip_and_reduce_motion(self):
        content = self.hero_view.read_text(encoding="utf-8")
        self.assertIn("rotation3DEffect", content)
        self.assertIn("axis: (x: 1, y: 0, z: 0)", content)
        self.assertIn("reduceMotion", content)
        self.assertIn("antigravityVortex", content)
        self.assertIn("delay(Double(index) * 0.040)", content)  # 40ms stagger


if __name__ == "__main__":
    unittest.main()
