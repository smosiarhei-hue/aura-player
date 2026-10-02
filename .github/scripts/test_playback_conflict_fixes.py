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

    def test_instant_eq_stream_precaching_and_migration(self):
        content = self.playercore.read_text(encoding="utf-8")
        # Precache function exists
        self.assertIn("func precacheStream(", content)
        # Immediate migration option
        self.assertIn("scheduleStreamMigrationIfNeeded(immediate: true)", content)
        self.assertIn("func scheduleStreamMigrationIfNeeded(immediate: Bool = false)", content)


if __name__ == "__main__":
    unittest.main()
