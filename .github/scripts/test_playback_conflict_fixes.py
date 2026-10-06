# Path: .github/scripts/test_playback_conflict_fixes.py
"""Tests for Player Core and Audio Session background conflict fixes."""

import unittest
from pathlib import Path


class PlaybackConflictFixesTests(unittest.TestCase):
    def setUp(self):
        self.repo_root = Path(__file__).resolve().parent.parent.parent
        self.playercore = self.repo_root / "Sonivo" / "playercore.swift"
        self.playback_audio_session = self.repo_root / "Sonivo" / "playbackaudiosession.swift"

    def test_audio_session_activation_in_start_and_resume(self):
        content = self.playercore.read_text(encoding="utf-8")
        # In start(at:), audio session is actively claimed for playback
        self.assertIn("PlaybackAudioSessionCoordinator.shared.activateForPlayback()", content)
        # start(at:) guarantees isPlaying = true
        self.assertIn("isPlaying = true", content)

    def test_background_task_in_handle_track_finish(self):
        content = self.playercore.read_text(encoding="utf-8")
        # Background task assertion during auto-advance on lock screen
        self.assertIn('UIApplication.shared.beginBackgroundTask(withName: "Sonivo.handleTrackFinish")', content)

    def test_release_audio_session_protection(self):
        content = self.playercore.read_text(encoding="utf-8")
        # Do not deactivate audio session if queue is active
        self.assertIn("currentTrack == nil", content)

    def test_eq_stream_migration_is_explicit_and_never_precached(self):
        content = self.playercore.read_text(encoding="utf-8")
        # Ordinary listening must not download every complete track.
        self.assertNotIn("func precacheStream(", content)
        self.assertIn("Ordinary playback stays streaming-only", content)
        # Native migration remains available after an explicit EQ action.
        self.assertIn("scheduleStreamMigrationIfNeeded(immediate: true)", content)
        self.assertIn("func scheduleStreamMigrationIfNeeded(immediate: Bool = false)", content)

    def test_smart_headphone_eq(self):
        content = self.playercore.read_text(encoding="utf-8")
        self.assertIn("var eqHeadphonesOnly: Bool", content)
        self.assertIn("var isHeadphonesConnected: Bool", content)
        self.assertIn("var isEQEffectivelyActive: Bool", content)
        self.assertIn("func handleAudioRouteChange()", content)
        # Check that applyEQ respects effective EQ active state
        self.assertIn("let on = isEQEffectivelyActive", content)

    def test_smart_headphone_eq_ui(self):
        chrome_content = (self.repo_root / "Sonivo" / "playerchrome.swift").read_text(encoding="utf-8")
        self.assertIn("Только в наушниках", chrome_content)
        self.assertIn("$player.eqHeadphonesOnly", chrome_content)
        self.assertIn("Наушники • нативный EQ активен", chrome_content)
        self.assertIn("Нативный EQ • работает локально без сети", chrome_content)
        self.assertIn("isEQPreparingNativeStream", chrome_content)

        settings_content = (self.repo_root / "Sonivo" / "settingsview.swift").read_text(encoding="utf-8")
        self.assertIn("Только для наушников", settings_content)
        self.assertIn("$player.eqHeadphonesOnly", settings_content)

    def test_dolby_atmos_and_lossless_support(self):
        content = self.playercore.read_text(encoding="utf-8")
        self.assertIn("var spatialAudioEnabled: Bool", content)
        self.assertIn("var isDolbyAtmosAvailable: Bool", content)
        self.assertIn("var isDolbyAtmosActive: Bool", content)
        self.assertIn("func applySpatialAudioConfiguration()", content)
        self.assertIn("func handleSpatialPlaybackCapabilitiesChanged()", content)
        # Check stream beat tap spatialization
        streambeat_content = (self.repo_root / "Sonivo" / "streambeat.swift").read_text(encoding="utf-8")
        self.assertIn("item.allowedAudioSpatializationFormats = PlayerCore.shared.spatialAudioEnabled ? .monoStereoAndMultichannel : []", streambeat_content)

    def test_dolby_atmos_and_lossless_ui(self):
        player_v2_content = (self.repo_root / "Sonivo" / "PlayerScreenV2.swift").read_text(encoding="utf-8")
        self.assertIn("qualityBadgeButton", player_v2_content)
        self.assertIn("SN.ink.opacity(0.50)", player_v2_content)
        self.assertIn('return "Dolby Atmos"', player_v2_content)
        self.assertIn('return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"', player_v2_content)
        self.assertIn("$player.spatialAudioEnabled", player_v2_content)

        settings_content = (self.repo_root / "Sonivo" / "settingsview.swift").read_text(encoding="utf-8")
        self.assertIn("Dolby Atmos (Пространственное аудио)", settings_content)
        self.assertIn("$player.spatialAudioEnabled", settings_content)


if __name__ == "__main__":
    unittest.main()

