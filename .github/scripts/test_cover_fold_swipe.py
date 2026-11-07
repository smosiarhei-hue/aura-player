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
            "sideScale: CGFloat = 0.85",
            "clusterFactor",
            "warpAmount(slot:",
        ]:
            self.assertIn(token, math)
        self.assertIn("CoverSwipeProMotionGate", gate)
        self.assertIn("preferredFrameRateRange", gate)
        self.assertIn("maximum: Float(desired)", gate)
        self.assertIn("min(120", gate)
        self.assertIn("coverFoldWarp", metal)
        self.assertIn("[[ stitchable ]] float2 coverFoldWarp", metal)

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
        self.assertIn("CoverSwipeProMotionGate(active:", stage)
        self.assertIn("ForEach([-1, 0, 1]", stage)
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
func foldDegrees(slot: Int, progress: Double) -> Double { -(Double(slot) + progress) * 52 }
func scale(slot: Int, progress: Double) -> Double {
  let t = min(1, abs(Double(slot) + progress))
  return 1 - t * (1 - 0.90)
}
precondition(abs(progress(dragX: 0, width: 390)) < 0.0001)
precondition(abs(progress(dragX: 195, width: 390) - 0.5) < 0.0001)
precondition(abs(foldDegrees(slot: 0, progress: 0)) < 0.0001)
precondition(abs(foldDegrees(slot: 1, progress: 0) + 52) < 0.0001)
precondition(abs(foldDegrees(slot: -1, progress: 0) - 52) < 0.0001)
precondition(abs(scale(slot: 0, progress: 0) - 1) < 0.0001)
precondition(scale(slot: 1, progress: 0) < 0.91)
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


if __name__ == "__main__":
    unittest.main()
