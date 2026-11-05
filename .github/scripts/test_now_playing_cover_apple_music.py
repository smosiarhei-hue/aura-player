#!/usr/bin/env python3
"""Apple Music–style Now Playing cover contracts.

The cover must stay an intact continuous square. Atmosphere is a separate
full-bleed native-blur layer behind the player — never a dissolve mask on art.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAYER = (ROOT / "Sonivo/PlayerScreenV2.swift").read_text()


class NowPlayingCoverAppleMusicTests(unittest.TestCase):
    def test_atmosphere_is_full_bleed_native_blur(self):
        self.assertIn("NowPlayingAtmosphere", PLAYER)
        self.assertIn("UIBlurEffect(style: .systemChromeMaterialDark)", PLAYER)
        self.assertIn("scaleAspectFill", PLAYER)
        self.assertNotIn("DownwardCoverWash", PLAYER)
        # No dissolve mask over the square cover stage.
        stage = PLAYER.split("private func artworkStage(", 1)[1].split(
            "private func inlineLyricsStage", 1
        )[0]
        self.assertNotIn(".mask(", stage)
        self.assertNotIn("LinearGradient", stage)

    def test_cover_is_dominant_continuous_square(self):
        self.assertIn(
            "let standardArtworkStageHeight = min(totalWidth - coverInset * 2, totalHeight * 0.50)",
            PLAYER,
        )
        stage = PLAYER.split("private func artworkStage(", 1)[1].split(
            "private func inlineLyricsStage", 1
        )[0]
        self.assertIn("RoundedRectangle(cornerRadius: 18, style: .continuous)", stage)
        self.assertIn("playScale = player.isPlaying ? 1.0 : 0.92", stage)
        self.assertIn(".interactiveSpring(response: 0.38, dampingFraction: 0.75)", stage)
        # Intact square — clipShape only, no wash overlay on the art.
        self.assertIn(".clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))", stage)

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


if __name__ == "__main__":
    unittest.main()
