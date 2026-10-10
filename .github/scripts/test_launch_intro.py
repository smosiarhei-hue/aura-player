from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LaunchIntroTests(unittest.TestCase):
    def test_native_launch_does_not_defer_root_creation(self):
        app=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('WindowGroup { SonivoLaunchHost() }',app)
        self.assertLess(intro.index('RootView(onExternalPlaybackOpen: finish)'),intro.index('if !session.isFinished'))
        self.assertIn('.allowsHitTesting(session.isFinished)',intro)
        self.assertIn('.accessibilityHidden(!session.isFinished)',intro)
        for bad in ['AVPlayer(', 'URLSession', 'Thread.sleep','Timer.scheduledTimer','DispatchQueue.main.asyncAfter','repeatForever']:
            self.assertNotIn(bad,intro)
    def test_skip_background_and_external_playback_are_handled(self):
        app=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        for expected in ['Button("Пропустить"', '.task(id: scenePhase)', 'if session.hasStarted { finish() }', '.onChange(of: player.isPlaying)', '.onDisappear { finish() }']:
            self.assertIn(expected,intro)
        self.assertEqual(app.count('onExternalPlaybackOpen?(); showPlayer = true'),3)
        self.assertIn('session.begin(isActive: true, isPlaying: player.isPlaying)',intro)
        self.assertNotIn('.onOpenURL',intro) # RootView keeps the existing external playback handlers.
    def test_haptics_and_animation_share_timeline_and_respect_preferences(self):
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        for expected in ['accessibilityReduceMotion','SettingsStore.shared.hapticsEnabled','supportsHaptics','engine.playsHapticsOnly = true','SonivoLaunchMotion.hapticOnsets','SonivoLaunchMotion.hapticStrengths','CACurrentMediaTime() + lead','engine.currentTime + lead','CHHapticTimeImmediate','haptics.stop()']:
            self.assertIn(expected,intro)
        self.assertNotIn('audioContinuous',intro)
        self.assertNotIn('MusicHapticsManager',intro)
        self.assertIn('paused: reduceMotion || scenePhase != .active',intro)
    def test_intro_is_small_finite_native_brand_reveal(self):
        model=(ROOT/'Sonivo/SonivoLaunchMotion.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('static let duration = 1.85',model)
        self.assertIn('static let reducedDuration = 0.35',model)
        self.assertIn('letterProgress(at: time, index: index)',intro)
        self.assertIn('ForEach(0..<5',intro)
        self.assertIn('.accessibilityLabel("Sonivo")',intro)
        self.assertIn('.frame(minWidth: 120, minHeight: 44)',intro)
        self.assertNotIn('UIScreen.main',intro)
if __name__=='__main__':unittest.main()
