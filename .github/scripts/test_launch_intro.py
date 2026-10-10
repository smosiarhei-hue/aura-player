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
    def test_accessibility_sizes_keep_brand_and_skip_without_tagline_crowding(self):
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('dynamicTypeSize',intro)
        self.assertIn('if !dynamicTypeSize.isAccessibilitySize',intro)
        self.assertIn('.accessibilityLabel("Sonivo")',intro)
        self.assertIn('Button("Пропустить"',intro)
    def test_intro_is_large_then_standard_true_focus_not_old_letter_reveal(self):
        model=(ROOT/'Sonivo/SonivoLaunchMotion.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('static let duration = 4.20',model)
        self.assertIn('static let reducedDuration = 0.35',model)
        for expected in ['focusedWord("Sonivo"','focusedWord("Твоя"','focusedWord("музыка"','.blur(radius: blur)','.anchorPreference(key: SonivoLaunchFocusBounds.self','.overlayPreferenceValue(SonivoLaunchFocusBounds.self)','cornerPath(in: bounds)','SonivoLaunchMotion.zoom(at: time, peak: peak)','measuredWordWidth','measuredGroupHeight','SonivoLaunchMotion.focusPadding * 2']:
            self.assertIn(expected,intro)
        for removed in ['letterProgress','sweep(at:','soundMark(']:
            self.assertNotIn(removed,intro)
        self.assertIn('.frame(minWidth: 120, minHeight: 44)',intro)
        self.assertNotIn('UIScreen.main',intro)
        self.assertIn('zoomTicks',intro)
        self.assertIn('strength * 0.55',intro)
    def test_focus_preferences_are_not_actor_isolated_shared_state(self):
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('nonisolated private struct SonivoLaunchFocusBounds: PreferenceKey',intro)
        self.assertIn('static var defaultValue: [Int: Anchor<CGRect>] { [:] }',intro)
        self.assertNotIn('static var defaultValue: [Int: Anchor<CGRect>] =',intro)
if __name__=='__main__':unittest.main()
