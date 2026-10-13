from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LaunchIntroTests(unittest.TestCase):
    def test_native_launch_does_not_defer_root_creation(self):
        app=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('WindowGroup { SonivoLaunchHost() }',app)
        self.assertLess(intro.index('RootView(onExternalPlaybackOpen: finish)'),intro.index('if !session.isFinished'))
        self.assertIn('.allowsHitTesting(session.isFinished || revealingHome)',intro)
        self.assertIn('.accessibilityHidden(!session.isFinished && !revealingHome)',intro)
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
    def test_resonance_replaces_true_focus_with_finite_ring_and_word_reveal(self):
        model=(ROOT/'Sonivo/SonivoLaunchMotion.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        symbol=(ROOT/'Sonivo/SonivoResonanceSymbol.swift').read_text()
        self.assertIn('static let duration = 3.0',model)
        self.assertIn('static let reducedDuration = 0.35',model)
        for expected in ['SonivoResonanceSymbol(time: time', 'SonivoLaunchWordmark(time: time',
                         'taglineOpacity(at: time)']:
            self.assertIn(expected,intro)
        for removed in ['focusedWord(', 'cornerPath(', 'SonivoLaunchFocusBounds', 'zoomTicks']:
            self.assertNotIn(removed,intro)
        self.assertIn('.frame(minWidth: 120, minHeight: 44)',intro)
        self.assertNotIn('UIScreen.main',intro)
        self.assertIn('hapticTransient',intro)
        self.assertIn('hapticContinuous',intro)
        self.assertIn('let tailDurations = [0.105, 0.055]',intro)
        self.assertIn('CHHapticParameterCurve(parameterID: .hapticIntensityControl',intro)
        self.assertIn('Image("ResonanceLaunchLogo")',symbol)
        self.assertIn('sonivoLaunchRadialExposure',symbol)

    def test_visual_scene_has_no_actor_unsafe_preference_or_shader_callback(self):
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        symbol=(ROOT/'Sonivo/SonivoResonanceSymbol.swift').read_text()
        for removed in ['PreferenceKey', 'overlayPreferenceValue', '.visualEffect']:
            self.assertNotIn(removed,intro)
        for forbidden in ['URLSession', 'AVPlayer', 'Timer.', 'repeatForever', 'Data(base64Encoded:']:
            self.assertNotIn(forbidden,symbol)
        self.assertIn('!reduceTransparency',symbol)
        self.assertIn('contrast != .increased',symbol)
if __name__=='__main__':unittest.main()
