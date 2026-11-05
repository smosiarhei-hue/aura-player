#!/usr/bin/env python3
"""Apple Music–style Now Playing cover contracts.

Edge-to-edge top art soft-dissolves into a full-bleed native-blur atmosphere.
The sharp cover is masked — never a floating inset card with chrome.
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
        self.assertIn(
            "let standardArtworkStageHeight = min(totalWidth, totalHeight * 0.48)",
            PLAYER,
        )
        self.assertIn("coverAccentWash", PLAYER)
        self.assertIn("-standardArtworkStageHeight * 0.08", PLAYER)
        stage = PLAYER.split("private func artworkStage(", 1)[1].split(
            "private func inlineLyricsStage", 1
        )[0]
        # Full-bleed art dissolves into the wash — no inset card chrome.
        self.assertIn(".mask(coverDissolveMask)", stage)
        self.assertNotIn("RoundedRectangle(cornerRadius: 18", stage)
        self.assertNotIn(".shadow(", stage)
        self.assertIn("playScale = player.isPlaying ? 1.0 : 0.97", stage)
        self.assertIn(".interactiveSpring(response: 0.38, dampingFraction: 0.75)", stage)
        self.assertIn("coverDissolveMask", PLAYER)
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
