from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LaunchIntroTests(unittest.TestCase):
    def test_native_launch_does_not_defer_root_creation(self):
        app=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('WindowGroup { SonivoLaunchHost() }',app)
        self.assertLess(intro.index('RootView(onExternalPlaybackOpen: finish)'),intro.index('if isShowingIntro'))
        self.assertIn('.allowsHitTesting(!isShowingIntro || revealingHome)',intro)
        self.assertIn('.accessibilityHidden(isShowingIntro && !revealingHome)',intro)
        for bad in ['AVPlayer(', 'URLSession', 'Thread.sleep','Timer.scheduledTimer','DispatchQueue.main.asyncAfter','repeatForever']:
            self.assertNotIn(bad,intro)
    def test_background_and_external_playback_are_handled(self):
        app=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        for expected in ['.task(id: scenePhase)', 'if startupClaimed { finish() }', '.onChange(of: player.isPlaying)', '.onDisappear { finish() }']:
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
    def test_accessibility_sizes_keep_brand_without_tagline_crowding(self):
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('dynamicTypeSize',intro)
        self.assertIn('if !dynamicTypeSize.isAccessibilitySize',intro)
        self.assertIn('.accessibilityLabel("Sonivo")',intro)
        self.assertNotIn('Button("Пропустить"',intro)
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
        self.assertNotIn('onSkip',intro)
        self.assertNotIn('UIScreen.main',intro)
        self.assertIn('hapticTransient',intro)
        self.assertIn('hapticContinuous',intro)
        self.assertIn('let tailDurations = [0.260, 0.140]',intro)
        self.assertIn('CHHapticParameterCurve(parameterID: .hapticIntensityControl',intro)
        self.assertIn('Image("ResonanceLaunchLogo")',symbol)
        self.assertIn('sonivoLaunchRadialExposure',symbol)

    def test_only_slow_uncached_startup_can_show_overlay(self):
        host=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        model=(ROOT/'Sonivo/SonivoLaunchMotion.swift').read_text()
        service=(ROOT/'Sonivo/yandexmusicservice.swift').read_text()
        self.assertIn('session.hasStarted && !session.isFinished',host)
        self.assertIn('SonivoLaunchLifetime.shared.claim()',host)
        self.assertLess(host.index('SonivoLaunchLifetime.shared.claim()'),host.index('Task.sleep'))
        self.assertLess(host.index('SonivoStartupGate.debounceSeconds'),host.index('session.begin('))
        self.assertIn('guard scenePhase == .active, needsPreparation,',host)
        self.assertIn('if !preparing, session.hasStarted { finish() }',host)
        self.assertIn('if startupClaimed { finish() }',host)
        self.assertIn('restoringAccount || (scanningLibrary && !hasCachedTracks)',model)
        self.assertIn('guard !hasClaimed else { return false }',model)
        self.assertNotIn('UserDefaults',model)
        self.assertIn('isRestoringInitialAccount = currentUser == nil',service)
        self.assertIn('if accountGeneration == initialGeneration { isRestoringInitialAccount = false }',service)
        reset=service[service.index('private func resetPersonalState()'):]
        self.assertIn('isRestoringInitialAccount = false',reset)
        self.assertEqual(service.count('isRestoringInitialAccount = currentUser == nil'),1)
        # Manual/account sync itself cannot re-arm the cold-start flag.
        sync=service[service.index('func syncAccountData()'):service.index('private func resetPersonalState()')]
        self.assertNotIn('isRestoringInitialAccount = true',sync)

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
