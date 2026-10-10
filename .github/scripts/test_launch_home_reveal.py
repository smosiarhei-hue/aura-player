from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LaunchHomeRevealTests(unittest.TestCase):
    def test_handoff_reuses_existing_final_interval_without_delaying_startup(self):
        host = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        motion = (ROOT / "Sonivo/SonivoLaunchMotion.swift").read_text()
        self.assertEqual(host.count("RootView(onExternalPlaybackOpen: finish)"), 1)
        self.assertIn("static let duration = 4.20", motion)
        self.assertIn("static let fadeStart = 3.85", motion)
        self.assertIn("exitTransitionDuration = duration - fadeStart", motion)
        self.assertIn("epoch + SonivoLaunchMotion.fadeStart - CACurrentMediaTime()", host)
        self.assertIn("epoch + SonivoLaunchMotion.duration - CACurrentMediaTime()", host)
        self.assertLess(host.index("RootView("), host.index("try await Task.sleep"))
        self.assertLess(host.index("try Task.checkCancellation()"), host.index("revealingHome = true"))

    def test_native_blur_only_interpolates_during_handoff_and_does_not_remount_root(self):
        modifier = (ROOT / "Sonivo/SonivoLaunchHomeReveal.swift").read_text()
        host = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        motion = (ROOT / "Sonivo/SonivoLaunchMotion.swift").read_text()
        self.assertIn("ViewModifier, Animatable", modifier)
        self.assertIn("var animatableData: Double", modifier)
        self.assertIn("content.blur(radius: SonivoLaunchMotion.homeRevealBlur(", modifier)
        self.assertIn("progress > 0, progress < 1", motion)
        self.assertIn("progress: session.isFinished || revealingHome ? 1 : 0", host)
        self.assertIn(".blur(radius: reduceMotion ? 0 : exitBlurRadius)", host)
        self.assertIn("duration: SonivoLaunchMotion.exitTransitionDuration", host)
        self.assertNotIn("AnimatableModifier", modifier)
        self.assertNotIn("TimelineView", modifier)
        self.assertNotIn("drawingGroup", modifier)
        self.assertNotIn("snapshot", modifier.lower())

    def test_interruptions_are_immediate_and_do_not_force_navigation(self):
        host = (ROOT / "Sonivo/SonivoLaunchIntro.swift").read_text()
        finish = host[host.index("private func finish()"):host.index("/// Anchors")]
        self.assertIn("transaction.disablesAnimations = true", finish)
        self.assertIn("withTransaction(transaction) { session.finish() }", finish)
        self.assertIn("haptics.stop()", finish)
        self.assertNotIn("Task.sleep", finish)
        self.assertNotIn(".animation(", finish)
        self.assertIn(".transition(.identity)", host)
        self.assertIn(".allowsHitTesting(session.isFinished)", host)
        self.assertIn(".accessibilityHidden(!session.isFinished)", host)
        for wrong_navigation in ["tab =", "showPlayer =", "NavigationStack(", "PlayerCore.shared.play"]:
            self.assertNotIn(wrong_navigation, host)
        self.assertIn("if !reduceMotion {", host)


if __name__ == "__main__":
    unittest.main()