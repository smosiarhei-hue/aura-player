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
        for expected in ['accessibilityReduceMotion','SettingsStore.shared.hapticsEnabled','supportsHaptics','engine.playsHapticsOnly = true','SonivoBrandLaunchMotion.hapticOnsets','SonivoBrandLaunchMotion.hapticStrengths','CACurrentMediaTime() + lead','engine.currentTime + lead','CHHapticTimeImmediate','haptics.stop()']:
            self.assertIn(expected,intro)
        self.assertNotIn('audioContinuous',intro)
        self.assertNotIn('MusicHapticsManager',intro)
        self.assertIn('paused: reduceMotion || scenePhase != .active',intro)
    def test_accessibility_sizes_keep_brand_without_tagline_crowding(self):
        intro=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('dynamicTypeSize',intro)
        self.assertIn('if !dynamicTypeSize.isAccessibilitySize',(ROOT/'Sonivo/SonivoBrandLaunchScene.swift').read_text())
        self.assertIn('.accessibilityLabel("Sonivo")',intro)
        self.assertNotIn('Button("Пропустить"',intro)
    def test_new_brand_scene_replaces_legacy_material_with_original_vectors(self):
        host=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        scene=(ROOT/'Sonivo/SonivoBrandLaunchScene.swift').read_text()
        motion=(ROOT/'Sonivo/SonivoBrandLaunchMotion.swift').read_text()
        self.assertIn('SonivoBrandLaunchScene(time: time',host)
        for old in ['SonivoResonanceSymbol(', 'SonivoLaunchWordmark(', 'SonivoLaunchTypography.prepare()']:
            self.assertNotIn(old,host)
        for expected in ['SonivoLaunchSignatureShape()', 'SonivoLaunchNameShape()', '.trim(from: 0',
                         'SonivoBrandLaunchMotion.bar(time, index: index)', 'SN.accent']:
            self.assertIn(expected,scene)
        self.assertIn('static let duration = 4.2',motion)
        self.assertIn('static let reducedDuration = 0.35',motion)
        self.assertIn('CHHapticPattern(events: events, parameters: [])',host)
        self.assertNotIn('.hapticContinuous',host)

    def test_every_cold_start_gets_intro_without_waiting_for_preparation(self):
        host=(ROOT/'Sonivo/SonivoLaunchIntro.swift').read_text()
        model=(ROOT/'Sonivo/SonivoLaunchMotion.swift').read_text()
        self.assertIn('session.hasStarted && !session.isFinished',host)
        self.assertIn('SonivoLaunchLifetime.shared.claim()',host)
        self.assertLess(host.index('session.begin('),host.index('Task.sleep'))
        self.assertIn('guard scenePhase == .active,',host)
        self.assertIn('if startupClaimed { finish() }',host)
        for obsolete in ['needsPreparation', 'debounceSeconds', 'isRestoringInitialAccount',
                         'library.isScanning', 'library.tracks']:
            self.assertNotIn(obsolete,host)
        self.assertNotIn('needsPreparation',model)
        self.assertIn('guard !hasClaimed else { return false }',model)
        self.assertIn('static let shared = SonivoLaunchLifetime()',model)
        self.assertNotIn('UserDefaults',model)

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
