#!/usr/bin/env python3
"""Apple Music–style Now Playing cover + scrubber contracts.

Edge-to-edge top art soft-dissolves into a full-bleed native-blur atmosphere.
Seek is a thin capsule; volume is a thicker pill without a resting thumb.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAYER = (ROOT / "Sonivo/PlayerScreenV2.swift").read_text()


class NowPlayingCoverAppleMusicTests(unittest.TestCase):
    def test_atmosphere_is_full_bleed_native_blur(self):
        self.assertIn("NowPlayingAtmosphere", PLAYER)
        self.assertIn("UIBlurEffect(style: .systemMaterialDark)", PLAYER)
        self.assertIn("scaleAspectFill", PLAYER)
        self.assertNotIn("DownwardCoverWash", PLAYER)
        self.assertIn("coverDissolveMask", PLAYER)

    def test_cover_is_edge_to_edge_with_soft_dissolve(self):
        self.assertIn("reservedFirstScreenControls", PLAYER)
        self.assertIn("totalHeight - reservedFirstScreenControls", PLAYER)
        self.assertIn("coverAccentWash", PLAYER)
        self.assertIn("minHeight: totalHeight", PLAYER)
        self.assertIn("VStack(spacing: 8)", PLAYER)
        # Full-bleed — not the temporary inset-square experiment.
        self.assertNotIn("totalWidth - 40", PLAYER.split("GeometryReader { geo in", 1)[1].split("ZStack(alignment: .top)", 1)[0])
        self.assertNotIn("coverUpwardBlurMask", PLAYER)
        stage = PLAYER.split("private func artworkStage(", 1)[1].split(
            "private func inlineLyricsStage", 1
        )[0]
        self.assertIn(".mask(coverDissolveMask)", stage)
        self.assertIn(".frame(width: width, height: height)", stage)
        self.assertNotIn("RoundedRectangle(cornerRadius: 18", stage)
        self.assertNotIn(".shadow(", stage)
        self.assertIn("playScale = player.isPlaying ? 1.0 : 0.97", stage)
        self.assertIn(".interactiveSpring(response: 0.38, dampingFraction: 0.75)", stage)
        mask = PLAYER.split("private var coverDissolveMask:", 1)[1].split(
            "@ViewBuilder", 1
        )[0]
        self.assertIn("LinearGradient", mask)
        self.assertIn(".clear", mask)

    def test_cover_fills_square_not_letterboxed(self):
        layer = PLAYER.split("private func coverLayer(", 1)[1].split(
            "private var fallbackArtwork", 1
        )[0]
        self.assertIn(".scaledToFill()", layer)
        self.assertIn(".interpolation(.high)", layer)
        self.assertNotIn(".scaledToFit()", layer)

    def test_seek_and_volume_match_apple_music_bars(self):
        timeline = PLAYER.split("struct PlayerTimelineSection", 1)[1].split(
            "final class SystemVolumeManager", 1
        )[0]
        self.assertIn("let trackHeight: CGFloat = isScrubbing ? 6 : 3", timeline)
        self.assertIn("if isScrubbing", timeline)
        self.assertIn("Color.white.opacity", timeline)
        volume = PLAYER.split("struct FluidVolumeSlider", 1)[1].split(
            "struct VideoShotPlayerView", 1
        )[0]
        self.assertIn("thicker pill volume", volume)
        self.assertIn("let trackHeight: CGFloat = isDragging ? 10 : 7", volume)
        self.assertNotIn("Circle()", volume)
        self.assertIn("speaker.fill", volume)
        self.assertIn("speaker.wave.3.fill", volume)

    def test_now_playing_forces_dark_over_atmosphere(self):
        self.assertIn(
            "(isFullScreenVideoShot || !showLyricsMode) ? .dark : preferredScheme",
            PLAYER,
        )

    def test_first_screen_utility_row_matches_apple_music(self):
        self.assertIn("primaryUtilityRow", PLAYER)
        utility = PLAYER.split("private var primaryUtilityRow:", 1)[1].split(
            "private var trackWaveButton", 1
        )[0]
        self.assertIn("quote.bubble", utility)
        self.assertIn("AirPlayButtonView()", utility)
        self.assertIn("list.bullet", utility)


if __name__ == "__main__":
    unittest.main()
