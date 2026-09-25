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
        self.shake_overlay = self.repo_root / "Aurora" / "WaveShakeOverlayView.swift"

    def test_files_exist(self):
        self.assertTrue(self.swift_manager.exists(), "AntigravityTransitionManager.swift missing")
        self.assertTrue(self.metal_shader.exists(), "AntigravityVortex.metal missing")
        self.assertTrue(self.hero_view.exists(), "MyWaveHeroView.swift missing")
        self.assertTrue(self.home_view.exists(), "AuraHomeRedesignedView.swift missing")
        self.assertTrue(self.shake_overlay.exists(), "WaveShakeOverlayView.swift missing")

    def test_anti_pocket_and_motion_detector(self):
        content = self.swift_manager.read_text(encoding="utf-8")
        # Gravity subtraction via userAcceleration
        self.assertIn("userAcceleration", content)
        # Proximity sensor enabled and checked
        self.assertIn("isProximityMonitoringEnabled", content)
        self.assertIn("proximityState", content)
        # Zero-crossing reversal tracking for deliberate shake
        self.assertIn("reversalsCount", content)
        # 120 Hz update rate
        self.assertIn("1.0 / 120.0", content)
        # Debounce 1.2s
        self.assertIn("1.2", content)
        # Main screen lifecycle check
        self.assertIn("isOnMainScreen", content)

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

    def test_hero_view_3d_flip_and_no_yellow(self):
        content = self.hero_view.read_text(encoding="utf-8")
        self.assertIn("rotation3DEffect", content)
        self.assertIn("axis: (x: 1, y: 0, z: 0)", content)
        self.assertIn("reduceMotion", content)
        self.assertIn("antigravityVortex", content)
        self.assertIn("delay(Double(index) * 0.040)", content)  # 40ms stagger
        # Yellow signature should be eliminated from hero view
        self.assertNotIn("#FBE029", content)
        self.assertNotIn("Color(red: 0.98, green: 0.88, blue: 0.16)", content)

    def test_vertical_wave_120hz_and_app_colors(self):
        content = self.shake_overlay.read_text(encoding="utf-8")
        # 120 Hz ProMotion timeline
        self.assertIn("1.0 / 120.0", content)
        self.assertIn("TimelineView", content)
        # Vertical sweep calculations
        self.assertIn("yCrest", content)
        # No signature yellow
        self.assertNotIn("#FBE029", content)
        # Clean app colors
        self.assertIn("Electric Cyan", content)

    def test_home_view_guards(self):
        content = self.home_view.read_text(encoding="utf-8")
        self.assertIn("proximityState", content)
        self.assertIn("onDisappear", content)
        self.assertIn("isOnMain", content)

    def test_automix_clean_equal_power_and_timing(self):
        timing_file = self.repo_root / "Aurora" / "AutoMix" / "AutoMixTransitionTiming.swift"
        timing_content = timing_file.read_text(encoding="utf-8")
        # Incoming track starts at 0.0 (natural musical intro)
        self.assertIn("return 0.0", timing_content)
        # Punchy, vocal-safe 2.8 - 3.5s blend length (prevents vocal clash)
        self.assertIn("min(3.5, max(2.8", timing_content)

        player_file = self.repo_root / "Aurora" / "playercore.swift"
        player_content = player_file.read_text(encoding="utf-8")
        # 3-phase DJ vocal-safe gain shaping
        self.assertIn("p < 0.35", player_content)
        self.assertIn("p < 0.65", player_content)
        self.assertIn("streamSourceVol = max(0.08, 0.85 * Float(cos(Double(s) * .pi * 0.5)))", player_content)
        self.assertIn("streamTargetVol = 0.15 + 0.70 * Float(sin(Double(s) * .pi * 0.5))", player_content)
        # Seamless stream player handoff without dropout
        self.assertIn("activeStreamingPlayer = incomingPlayer", player_content)
        self.assertIn("outgoingPlayer.pause()", player_content)
        self.assertIn("CMTimeGetSeconds(activeStreamingPlayer.currentTime())", player_content)

        models_file = self.repo_root / "Aurora" / "models.swift"
        models_content = models_file.read_text(encoding="utf-8")
        # Pure Equal-Power Cosine Crossfade for local files
        self.assertIn("let outVol = Float(cos(p * (.pi / 2)))", models_content)
        self.assertIn("let inVol = Float(sin(p * (.pi / 2)))", models_content)

    def test_my_wave_fresh_random_seed(self):
        catalog_file = self.repo_root / "Aurora" / "sonivocatalog.swift"
        catalog_content = catalog_file.read_text(encoding="utf-8")
        # Wave supports forceFresh and seeds from last liked track
        self.assertIn("forceFresh: Bool = false", catalog_content)
        self.assertIn("LibraryStore.shared.favorites", catalog_content)
        self.assertIn("randomElement()", catalog_content)
        self.assertIn("service.remember(", catalog_content)
        self.assertIn("ymTrackId: lastLikedYmId", catalog_content)


if __name__ == "__main__":
    unittest.main()
