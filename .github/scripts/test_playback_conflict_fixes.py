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
        # Paused tracks retain their queue, but must return audio focus.
        idle = content.split("func releaseAudioSessionIfIdle()", 1)[1].split("private func setupStreamingPlayer", 1)[0]
        self.assertIn("guard !isPlaying else", idle)
        self.assertNotIn("currentTrack == nil", idle)

    def test_eq_uses_realtime_processing_and_never_precaches(self):
        content = self.playercore.read_text(encoding="utf-8")
        # Ordinary listening must not download every complete track.
        self.assertNotIn("func precacheStream(", content)
        self.assertIn("Ordinary playback stays streaming-only", content)
        # EQ must not migrate; explicit vocal separation retains its guarded migration API.
        eq = content.split("var eqEnabled: Bool", 1)[1].split("/// Smart Headphone EQ", 1)[0]
        self.assertNotIn("scheduleStreamMigrationIfNeeded", eq)
        self.assertIn("StreamBeatTap.shared.updateEQ", content)
        self.assertIn("func scheduleStreamMigrationIfNeeded(immediate: Bool = false)", content)

    def test_smart_headphone_eq(self):
        content = self.playercore.read_text(encoding="utf-8")
        self.assertIn("var eqHeadphonesOnly: Bool", content)
        self.assertIn("var isHeadphonesConnected: Bool", content)
        self.assertIn("var isEQEffectivelyActive: Bool", content)
        self.assertIn("func handleAudioRouteChange()", content)
        # Check that applyEQ respects effective EQ active state
        self.assertIn("let on = shouldApplyUserEQ", content)

    def test_smart_headphone_eq_ui(self):
        eq_content = (self.repo_root / "Sonivo" / "PlayerEQSheetView.swift").read_text(encoding="utf-8")
        self.assertIn("Только в наушниках", eq_content)
        self.assertIn("$player.eqHeadphonesOnly", eq_content)
        self.assertIn("Наушники • EQ в реальном времени", eq_content)
        self.assertIn("EQ • обработка воспроизводимого звука", eq_content)
        self.assertIn("isEQPreparingNativeStream", eq_content)

        settings_content = (self.repo_root / "Sonivo" / "settingsview.swift").read_text(encoding="utf-8")
        self.assertIn("Только для наушников", settings_content)
        self.assertIn("$player.eqHeadphonesOnly", settings_content)

    def test_system_spatial_audio_and_lossless_support(self):
        content = self.playercore.read_text(encoding="utf-8")
        self.assertIn("var spatialAudioEnabled: Bool", content)
        self.assertIn("var isSpatialOutputSupported: Bool", content)
        self.assertIn("var spatialAudioStatusText: String", content)
        self.assertIn("func applySpatialAudioConfiguration()", content)
        self.assertIn("func handleSpatialPlaybackCapabilitiesChanged()", content)
        # Check stream beat tap spatialization
        streambeat_content = (self.repo_root / "Sonivo" / "streambeat.swift").read_text(encoding="utf-8")
        self.assertIn("item.allowedAudioSpatializationFormats = PlayerCore.shared.spatialAudioEnabled ? .monoStereoAndMultichannel : []", streambeat_content)

    def test_system_spatial_audio_and_lossless_ui(self):
        player_v2_content = (self.repo_root / "Sonivo" / "PlayerScreenV2.swift").read_text(encoding="utf-8")
        self.assertIn("qualityBadgeButton", player_v2_content)
        self.assertIn("SN.ink.opacity(0.50)", player_v2_content)
        self.assertNotIn('return "Dolby Atmos"', player_v2_content)
        self.assertIn("player.spatialAudioStatusText", player_v2_content)
        self.assertIn('PlaybackQualityFacts(codec: player.currentCodec, bitrate: player.currentBitrate)', player_v2_content)
        self.assertNotIn('return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"', player_v2_content)
        self.assertIn("$player.spatialAudioEnabled", player_v2_content)

        settings_content = (self.repo_root / "Sonivo" / "settingsview.swift").read_text(encoding="utf-8")
        self.assertIn("Системное пространственное аудио", settings_content)
        self.assertIn("$player.spatialAudioEnabled", settings_content)

    def test_more_menu_defers_sheets_so_menu_dismiss_does_not_bounce_them(self):
        content = (self.repo_root / "Sonivo" / "PlayerScreenV2.swift").read_text(encoding="utf-8")
        # Field report: ellipsis Menu → EQ/queue/settings flashed then bounced closed.
        open_modal = content.split("private func openModal(_ modal: ActivePlayerModal", 1)[1].split(
            "private func scheduleAfterMenuDismiss", 1
        )[0]
        self.assertIn("deferForMenu", open_modal)
        self.assertIn("scheduleAfterMenuDismiss { activeModal = modal }", open_modal)
        # Direct chrome buttons stay immediate; only Menu paths defer.
        self.assertIn("activeModal = modal", open_modal)
        deferral = content.split("private func scheduleAfterMenuDismiss", 1)[1].split(
            "private func togglePlayback", 1
        )[0]
        self.assertIn("milliseconds(320)", deferral)
        self.assertIn("guard !Task.isCancelled, isPresented", deferral)
        self.assertIn("pendingModalTask?.cancel()", content)
        more_menu = content.split("private var moreMenuButton:", 1)[1].split(
            "private var artistSelectionSheet", 1
        )[0]
        native_menu = (self.repo_root / 'Sonivo' / 'PlayerMoreMenu.swift').read_text(encoding='utf-8')
        self.assertIn('action("Текст песни"', native_menu)
        self.assertIn("scheduleAfterMenuDismiss", more_menu)
        self.assertIn("openModal(.equalizer, deferForMenu: true)", more_menu)
        # Leaving lyrics must not wipe EQ/queue sheets.
        lyrics_change = content.split(".onChange(of: showLyricsMode)", 1)[1].split(
            ".onReceive(NotificationCenter.default.publisher(for: .didUpdateCustomLyrics))", 1
        )[0]
        self.assertIn("if activeModal == .lyrics { activeModal = nil }", lyrics_change)
        self.assertNotIn("activeModal = nil\n            }\n        }\n        .onReceive", lyrics_change)
        # Nested NavigationStack around EQ/Settings caused sheet bounce.
        sheet = content.split(".sheet(item: $activeModal)", 1)[1].split(
            ".sheet(item: $selectedArtist)", 1
        )[0]
        self.assertIn("case .equalizer:\n                PlayerEQSheetView()", sheet)
        self.assertIn("case .settings:\n                SettingsView()", sheet)
        self.assertNotIn("NavigationStack {\n                switch modal", sheet)
        self.assertIn("minimumDistance: 8", content.split("lyricsControlsDeck", 1)[1].split(
            "artworkStage", 1
        )[0])


if __name__ == "__main__":
    unittest.main()

