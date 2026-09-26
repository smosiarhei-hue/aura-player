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

    def test_vocal_isolation_architecture_and_dsp(self):
        processing_file = self.repo_root / "Aurora" / "VocalIsolation" / "VocalIsolationProcessing.swift"
        self.assertTrue(processing_file.exists(), "VocalIsolationProcessing.swift must exist")
        content = processing_file.read_text(encoding="utf-8")
        # Protocol definition
        self.assertIn("protocol VocalIsolationProcessing: Sendable", content)
        # Mid-Side channel processing math
        self.assertIn("let mid = (left + right) * 0.5", content)
        self.assertIn("let side = (left - right) * 0.5", content)
        # Bass preservation filter
        self.assertIn("bassState1 += alphaBass * (mid - bassState1)", content)
        # Click-free smoothing ramp
        self.assertIn("smoothedLevel += (target - smoothedLevel) * rampFactor", content)
        # ML future extension point
        self.assertIn("class MLVocalIsolator: VocalIsolationProcessing", content)

        manager_file = self.repo_root / "Aurora" / "VocalIsolation" / "VocalIsolationManager.swift"
        self.assertTrue(manager_file.exists(), "VocalIsolationManager.swift must exist")
        mgr_content = manager_file.read_text(encoding="utf-8")
        self.assertIn("class VocalIsolationManager", mgr_content)
        self.assertIn("processBuffer", mgr_content)
        self.assertIn("processAudioBufferList", mgr_content)
        self.assertIn("AudioUnitAddRenderNotify", mgr_content)
        self.assertIn("migrateStreamToAudioEngineIfNeeded", mgr_content)

        player_file = self.repo_root / "Aurora" / "playercore.swift"
        player_content = player_file.read_text(encoding="utf-8")
        # PlayerCore stream migration to AVAudioEngine
        self.assertIn("func migrateStreamToAudioEngineIfNeeded()", player_content)
        self.assertIn("VocalIsolationManager.shared.attach(to: vocalUnit)", player_content)

        dual_deck_file = self.repo_root / "Aurora" / "Stage3DualDeckAudioEngine.swift"
        dual_content = dual_deck_file.read_text(encoding="utf-8")
        self.assertIn("VocalIsolationManager.shared.attach(to: userEQ)", dual_content)

    def test_vocal_isolation_ui_and_visibility(self):
        control_file = self.repo_root / "Aurora" / "VocalIsolation" / "VocalIsolationControlView.swift"
        self.assertTrue(control_file.exists(), "VocalIsolationControlView.swift must exist")
        ctrl_content = control_file.read_text(encoding="utf-8")
        # Vertical capsule slider matching reference design
        self.assertIn("Capsule()", ctrl_content)
        self.assertIn("stylizedMicrophoneIcon", ctrl_content)
        self.assertIn("mic.fill", ctrl_content)
        self.assertIn("sparkle", ctrl_content)
        self.assertIn("VocalIsolationUIConfig", ctrl_content)

        player_screen = self.repo_root / "Aurora" / "PlayerScreenV2.swift"
        ps_content = player_screen.read_text(encoding="utf-8")
        # View mode enum and visibility logic: visible ONLY in lyrics and karaoke
        self.assertIn("enum PlayerViewMode", ps_content)
        self.assertIn("isVocalToggleVisible: Bool", ps_content)
        self.assertIn("playerViewMode == .lyrics || playerViewMode == .karaoke", ps_content)
        self.assertIn("VocalIsolationControlView()", ps_content)

        lyrics_view = self.repo_root / "Aurora" / "lyricsview.swift"
        lv_content = lyrics_view.read_text(encoding="utf-8")
        self.assertIn("VocalIsolationControlView()", lv_content)

    def test_dify_models_and_service(self):
        dify_models = self.repo_root / "Aurora" / "Dify" / "DifyModels.swift"
        dify_service = self.repo_root / "Aurora" / "Dify" / "DifyService.swift"
        ai_playlist_service = self.repo_root / "Aurora" / "Dify" / "AIPlaylistGeneratorService.swift"
        ai_assistant_view = self.repo_root / "Aurora" / "Dify" / "AIMusicAssistantView.swift"
        dify_settings = self.repo_root / "Aurora" / "Dify" / "DifySettingsSheet.swift"

        self.assertTrue(dify_models.exists(), "DifyModels.swift must exist")
        self.assertTrue(dify_service.exists(), "DifyService.swift must exist")
        self.assertTrue(ai_playlist_service.exists(), "AIPlaylistGeneratorService.swift must exist")
        self.assertTrue(ai_assistant_view.exists(), "AIMusicAssistantView.swift must exist")
        self.assertTrue(dify_settings.exists(), "DifySettingsSheet.swift must exist")

        svc_content = dify_service.read_text(encoding="utf-8")
        self.assertIn("class DifyService", svc_content)
        self.assertIn("func sendMessage(", svc_content)
        self.assertIn("func extractPlaylist(", svc_content)
        self.assertIn("func cleanDisplayText(", svc_content)
        self.assertIn("https://api.dify.ai/v1", svc_content)

        gen_content = ai_playlist_service.read_text(encoding="utf-8")
        self.assertIn("class AIPlaylistGeneratorService", gen_content)
        self.assertIn("func resolveTracks(", gen_content)
        self.assertIn("func saveToLibrary(", gen_content)
        self.assertIn("func playNow(", gen_content)

    def test_dify_ui_integration(self):
        hero_view = self.repo_root / "Aurora" / "MyWaveHeroView.swift"
        hero_content = hero_view.read_text(encoding="utf-8")
        self.assertIn("showAIAssistant", hero_content)
        self.assertIn("sparkles", hero_content)

        home_view = self.repo_root / "Aurora" / "AuraHomeRedesignedView.swift"
        home_content = home_view.read_text(encoding="utf-8")
        self.assertIn("AIMusicAssistantView()", home_content)
        self.assertIn("showAIAssistant", home_content)
        self.assertIn("AI Куратор", home_content)

        lib_view = self.repo_root / "Aurora" / "libraryview.swift"
        lib_content = lib_view.read_text(encoding="utf-8")
        self.assertIn("AIMusicAssistantView()", lib_content)
        self.assertIn("AI Подборка", lib_content)

    def test_ai_dj_and_vibe_wave(self):
        dj_service = self.repo_root / "Aurora" / "Dify" / "AIDJService.swift"
        dj_badge = self.repo_root / "Aurora" / "Dify" / "AIDJTransitionBadgeView.swift"

        self.assertTrue(dj_service.exists(), "AIDJService.swift must exist")
        self.assertTrue(dj_badge.exists(), "AIDJTransitionBadgeView.swift must exist")

        svc_content = dj_service.read_text(encoding="utf-8")
        self.assertIn("class AIDJService", svc_content)
        self.assertIn("func generateVibeWave(", svc_content)
        self.assertIn("func commentary(", svc_content)
        self.assertIn("func prefetchCommentaryIfNeeded(", svc_content)

        player_screen = self.repo_root / "Aurora" / "PlayerScreenV2.swift"
        ps_content = player_screen.read_text(encoding="utf-8")
        self.assertIn("AIDJTransitionBadgeView(", ps_content)
        self.assertIn("startAIVibeWave()", ps_content)
        self.assertIn("prefetchCommentaryIfNeeded", ps_content)

        lib_view = self.repo_root / "Aurora" / "libraryview.swift"
        lib_content = lib_view.read_text(encoding="utf-8")
        self.assertIn("startAIVibeWave(for:", lib_content)
        self.assertIn("AI Вайб-волна", lib_content)

    def test_ai_videoshot_service(self):
        service_file = self.repo_root / "Aurora" / "VideoShot" / "AIVideoShotGeneratorService.swift"
        self.assertTrue(service_file.exists(), "AIVideoShotGeneratorService.swift must exist")

        content = service_file.read_text(encoding="utf-8")
        self.assertIn("class AIVideoShotGeneratorService", content)
        self.assertIn("func generateVideoShot(", content)
        self.assertIn("func localVideoShotURL(", content)
        self.assertIn("https://siftq.com/api/minimax-trial/video-generation", content)
        self.assertIn("X-MiniMax-Trial-Client", content)
        self.assertIn("X-Forwarded-For", content)
        self.assertIn("didGenerateAIVideoShot", content)

        dify_file = self.repo_root / "Aurora" / "Dify" / "DifyService.swift"
        dify_content = dify_file.read_text(encoding="utf-8")
        self.assertIn("generateVideoShotPrompt", dify_content)

        player_screen = self.repo_root / "Aurora" / "PlayerScreenV2.swift"
        ps_content = player_screen.read_text(encoding="utf-8")
        self.assertIn("AIVideoShotGeneratorService.shared", ps_content)
        self.assertIn("generateAIVideoShot()", ps_content)
        self.assertIn("didGenerateAIVideoShot", ps_content)


if __name__ == "__main__":
    unittest.main()


