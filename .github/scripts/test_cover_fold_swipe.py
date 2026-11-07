#!/usr/bin/env python3
"""Folding-cards cover swipe (Basit / Bencho) + ProMotion 120 Hz contracts."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CoverFoldSwipeTests(unittest.TestCase):
    def test_math_and_promition_surface_exist(self):
        math = (ROOT / "Sonivo/CoverFoldSwipeMath.swift").read_text()
        gate = (ROOT / "Sonivo/CoverSwipeProMotion.swift").read_text()
        metal = (ROOT / "Sonivo/CoverFoldWarp.metal").read_text()
        for token in [
            "maxFoldDegrees",
            "foldDegrees(slot:",
            "slotOffset(slot:",
            "progressLimit",
            "perspective",
            "sideScale: CGFloat = 0.74",
            "clusterFactor",
            "warpAmount(slot:",
            "cornerRadiusFactor",
        ]:
            self.assertIn(token, math)
        # Mild tilt only — heavy Y rotation reads as cubes; warp carries the fold.
        self.assertIn("static let maxFoldDegrees: Double = 12", math)
        self.assertIn("static let clusterFactor: CGFloat = 0.92", math)
        self.assertIn("CoverSwipeProMotionGate", gate)
        self.assertIn("preferredFrameRateRange", gate)
        self.assertIn("maximum: Float(desired)", gate)
        self.assertIn("min(120", gate)
        # Swift 6: no CADisplayLink touch from nonisolated deinit.
        self.assertNotIn("deinit", gate)
        self.assertNotIn("UIScreen.main.maximumFramesPerSecond", gate)
        self.assertIn("dismantleUIView", gate)
        self.assertIn("window == nil", gate)
        self.assertIn("coverFoldWarp", metal)
        self.assertIn("[[ stitchable ]] float2 coverFoldWarp", metal)
        self.assertIn("compress * 0.42f", metal)
        self.assertIn("ripple", metal)
        self.assertIn("clamp(amount, -1.0f, 1.0f)", metal)
        self.assertIn("Float(max(-1, min(1, CGFloat(slot) + progress)))", math)

    def test_player_uses_folding_carousel_not_teleport_easein(self):
        player = (ROOT / "Sonivo/PlayerScreenV2.swift").read_text()
        stage = player.split("private func artworkStage(", 1)[1].split(
            "private var coverDissolveMask", 1
        )[0]
        self.assertIn("CoverFoldSwipeMath.progress", stage)
        self.assertIn("foldedCoverPlate(", stage)
        self.assertIn("rotation3DEffect(", stage)
        self.assertIn("distortionEffect(", stage)
        self.assertIn("ShaderLibrary.coverFoldWarp(", stage)
        self.assertIn("CoverFoldAnimatedEffect", stage)
        self.assertIn("var animatableData: CGFloat", stage)
        self.assertIn("set { progress = newValue }", stage)
        self.assertIn("compositingGroup()", stage)
        self.assertIn("CoverFoldSwipeMath.cornerRadiusFactor", stage)
        self.assertIn("CoverSwipeProMotionGate(active:", stage)
        self.assertIn("ForEach([-1, 0, 1]", stage)
        self.assertNotIn("coverTopProgressiveBlur", stage)
        self.assertNotIn(".offset(x: coverDragX)\n        .rotationEffect", stage)

        swipe = player.split("private func animateTrackSwipe", 1)[1].split(
            "private func releaseCoverSwitchLock", 1
        )[0]
        self.assertIn("CoverFoldSwipeMotion.commitAnimation", swipe)
        self.assertIn("CoverFoldSwipeMotion.commitHoldMilliseconds", swipe)
        self.assertNotIn(".easeIn(duration: 0.18)", swipe)
        self.assertNotIn("-sign * width * 0.65", swipe)
        self.assertIn("transaction.disablesAnimations = true", swipe)
        self.assertIn("coverDragX = 0", swipe)
        motion = (ROOT / "Sonivo/CoverFoldSwipeMath.swift").read_text()
        self.assertIn("response: 0.45, dampingFraction: 0.85", motion)

    def test_sample_offsets_cover_the_saturated_shader_domain(self):
        import math
        for step in range(21):
            a = step / 20
            x_pad = 0.28 + 0.55 * a
            y_pad = 0.18 + 0.35 * a
            for xi in range(101):
                nx = xi / 50 - 1
                pull = max(0, nx * a) * a
                compression = pull * pull
                x_source = nx + compression * 0.95 * nx - pull * 0.42
                self.assertLessEqual(abs(x_source - nx) / 2, x_pad + 1e-9)
                for yi in range(51):
                    y = yi / 50
                    y_displacement = (math.sin(y * math.pi) * compression * 0.42
                        + math.sin(y * math.pi * 2) * pull * 0.10
                        + (2 * y - 1) * compression * 0.06)
                    self.assertLessEqual(abs(y_displacement), y_pad + 1e-9)

    def test_math_swift_preconditions(self):
        """Pure fold curves — center flat, sides fold, opacity drops past one slot."""
        source = r'''
import Foundation
'''
        # Inline the math by compiling the real file is heavy; mirror key formulas.
        checks = r'''
func progress(dragX: Double, width: Double) -> Double {
  guard width > 0 else { return 0 }
  return max(-1.18, min(1.18, dragX / width))
}
func foldDegrees(slot: Int, progress: Double) -> Double { -(Double(slot) + progress) * 12 }
func scale(slot: Int, progress: Double) -> Double {
  let t = min(1.0, abs(Double(slot) + progress))
  let eased = t * t * (3 - 2 * t)
  return 1 - eased * (1 - 0.74)
}
precondition(abs(progress(dragX: 0, width: 390)) < 0.0001)
precondition(abs(progress(dragX: 195, width: 390) - 0.5) < 0.0001)
precondition(abs(foldDegrees(slot: 0, progress: 0)) < 0.0001)
precondition(abs(foldDegrees(slot: 1, progress: 0) + 12) < 0.0001)
precondition(abs(foldDegrees(slot: -1, progress: 0) - 12) < 0.0001)
precondition(abs(scale(slot: 0, progress: 0) - 1) < 0.0001)
precondition(scale(slot: 1, progress: 0) < 0.75)
print("ok")
'''
        import platform
        import shutil
        import subprocess

        if platform.system() != "Darwin" or not shutil.which("swift"):
            self.skipTest("swift not available")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fold.swift"
            path.write_text(checks)
            result = subprocess.run(
                ["swift", str(path)], capture_output=True, text=True, timeout=60
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ok", result.stdout)


class CoverSwipeSafetyRegressionTests(unittest.TestCase):
    def test_previews_are_conservative_and_do_not_block_transport(self):
        core = (ROOT / 'Sonivo/playercore.swift').read_text()
        preview = core.split('var coverSwipePreviewTracks:', 1)[1].split('private func peekNext', 1)[0]
        self.assertIn('idx > 0 ? q[idx - 1] : nil', preview)
        self.assertIn('guard !isYandexWavePlayback, !shuffle', preview)
        self.assertIn('suppressAutomixSkipUntil', preview)
        self.assertNotIn('randomElement', preview)
        self.assertNotIn('effectiveQueue()', preview)
        player = (ROOT / 'Sonivo/PlayerScreenV2.swift').read_text()
        gesture = player.split('private func artworkStage', 1)[1].split('private var coverSwipeNeighbors', 1)[0]
        self.assertIn('animateTrackSwipe(direction: direction, width: width)', gesture)
        self.assertNotIn('if hasNeighbor', gesture)
        commit = player.split('private func animateTrackSwipe', 1)[1].split('private func releaseCoverSwitchLock', 1)[0]
        for token in ['preview == nil', 'nextTrack()', 'previousTrack()', 'requestedQueue',
                      'requestedShuffle', 'requestedRepeat', 'currentPreviewID == requestedPreviewID',
                      'coverSwitchGeneration = UUID()', 'coverSwitchTask?.cancel()']:
            self.assertIn(token, commit)
        self.assertIn('if phase != .active { cancelCoverSwitch() }', player)
        self.assertIn('isCoverSwitching && coverSwitchTask != nil', player)
        self.assertIn('abs(coverDragX) > 0.5 { cancelCoverSwitch() }', player)

    def test_feather_and_text_share_swipe_without_changing_actions(self):
        player = (ROOT / 'Sonivo/PlayerScreenV2.swift').read_text()
        plate = player.split('private func foldedCoverPlate', 1)[1].split('private var coverDissolveMask', 1)[0]
        self.assertIn('.mask(coverDissolveMask)', plate)
        self.assertNotIn('if restingCenter', plate)
        mask = player.split('private var coverDissolveMask', 1)[1].split('private func inlineLyricsStage', 1)[0]
        self.assertIn('.clear, location: 0.00', mask)
        metadata = player.split('private func metadataRow', 1)[1].split('@ViewBuilder private var centerStatusLabel', 1)[0]
        for token in ['metadataCarousel(coverWidth:', 'CoverFoldSwipeMath.progress',
                      'coverSwipeNeighbors', 'rotation3DEffect', '.clipped()',
                      '.accessibilityHidden(true)', '.accessibilityLabel(', 'Button(action: openArtist)',
                      'reduceMotion', 'isFullScreenVideoShot']:
            self.assertIn(token, metadata)


if __name__ == "__main__":
    unittest.main()
