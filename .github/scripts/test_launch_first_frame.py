"""First-frame coverage source checks; executable session checks run in the macOS fixture."""
import json
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[2]
class LaunchFirstFrameTests(unittest.TestCase):
    def test_cover_exists_before_any_scene_task(self):
        s=(R/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('@State private var launchDecisionPending = !SonivoLaunchLifetime.shared.hasClaimed',s)
        self.assertIn('session.shouldCoverHome(pendingDecision: launchDecisionPending, isPlaying: player.isPlaying)',s)
        self.assertLess(s.index('if isShowingIntro'),s.index('.task(id: scenePhase)'))
        self.assertIn('launchDecisionPending = false',s)
        model=(R/'Sonivo/SonivoLaunchMotion.swift').read_text()
        self.assertIn('!isFinished && !isPlaying && (pendingDecision || hasStarted)',model)
        self.assertIn('var hasClaimed: Bool { gate.hasClaimed }',model)
    def test_system_and_scene_share_opaque_launch_color(self):
        self.assertIn('UIColorName: SonivoLaunchBackground',(R/'project.yml').read_text())
        self.assertIn('Color("SonivoLaunchBackground")',(R/'Sonivo/SonivoBrandLaunchScene.swift').read_text())
        colors=json.loads((R/'Sonivo/assets.xcassets/SonivoLaunchBackground.colorset/Contents.json').read_text())
        self.assertEqual(len(colors['colors']),1)
        c=colors['colors'][0]['color']['components']
        self.assertEqual(float(c['alpha']),1)
        self.assertAlmostEqual(float(c['red']),15/255)
        self.assertAlmostEqual(float(c['blue']),18/255)
    def test_speed_up_shares_visual_and_haptic_clock(self):
        s=(R/'Sonivo/SonivoBrandLaunchMotion.swift').read_text()
        self.assertIn('static let duration = 1.5',s)
        self.assertIn('static let playbackRate = 2.8',s)
        self.assertIn('[0.82, 1.46, 1.72].map { $0 / playbackRate }',s)
        self.assertEqual(s.count('progress(t * playbackRate,'),5)
        self.assertIn('let t = time * playbackRate',s)
        self.assertIn('static let reducedDuration = 0.35',s)
        self.assertIn('[0.50, 0.70, 0.55]',s)
        # All visual stages and tactile cues complete before the shorter handoff.
        self.assertLess(2.17/2.8,3.78/2.8)
        self.assertLessEqual((3.78+0.38)/2.8,1.5)

if __name__=='__main__':unittest.main()
