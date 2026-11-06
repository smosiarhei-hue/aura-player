#!/usr/bin/env python3
"""Now Playing cover contracts.

Standard inset square cover (no full-bleed upscale) over a native UIBlur
atmosphere. Sharp art keeps display size; edges melt upward via a same-size
blurred twin — never scaleEffect on the cover to invent resolution.
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
        self.assertIn("coverUpwardEdgeMask", PLAYER)
        self.assertIn("coverUpwardBlurMask", PLAYER)

    def test_cover_is_standard_square_with_upward_edge_blur(self):
        self.assertIn("totalWidth - 40", PLAYER)
        self.assertIn("totalHeight * 0.44", PLAYER)
        self.assertIn("coverSide + min(56, coverSide * 0.18)", PLAYER)
        self.assertIn("coverAccentWash", PLAYER)
        self.assertIn("minHeight: totalHeight", PLAYER)
        self.assertIn("VStack(spacing: 6)", PLAYER)
        # No oversized full-bleed stage that upscales the sharp art.
        self.assertNotIn("reservedFirstScreenControls", PLAYER)
        self.assertNotIn("totalWidth * 0.90", PLAYER)
        stage = PLAYER.split("private func artworkStage(", 1)[1].split(
            "private func inlineLyricsStage", 1
        )[0]
        self.assertIn("coverUpwardBlurMask", stage)
        self.assertIn("coverUpwardEdgeMask", stage)
        self.assertIn(".blur(radius: 28)", stage)
        self.assertIn("offset(y: -(coverSide * 0.14))", stage)
        # Blur twin must not be scaleEffect-enlarged (that softens the art).
        self.assertNotIn(".scaleEffect(1.15)", stage)
        self.assertNotIn("RoundedRectangle(cornerRadius: 18", stage)
        self.assertNotIn(".shadow(", stage)
        self.assertIn("playScale = player.isPlaying ? 1.0 : 0.97", stage)
        self.assertIn(".interactiveSpring(response: 0.38, dampingFraction: 0.75)", stage)
        edge = PLAYER.split("private var coverUpwardEdgeMask:", 1)[1].split(
            "private var coverUpwardBlurMask:", 1
        )[0]
        self.assertIn("LinearGradient", edge)
        self.assertIn(".clear", edge)

    def test_cover_fills_square_not_letterboxed(self):
        layer = PLAYER.split("private func coverLayer(", 1)[1].split(
            "private var fallbackArtwork", 1
        )[0]
        self.assertIn(".scaledToFill()", layer)
        self.assertIn(".interpolation(.high)", layer)
        self.assertNotIn(".scaledToFit()", layer)

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
