"""Regression guards for AsyncRenderer colors and preserving shake settings."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class WaveCrashSafetyTests(unittest.TestCase):
    def test_dynamic_surface_provider_is_explicitly_nonisolated(self):
        theme=(ROOT/'Sonivo/theme.swift').read_text()
        self.assertIn('private nonisolated static func surface(light: UIColor, dark: UIColor) -> Color',theme)
        provider=theme.split('private nonisolated static func surface',1)[1].split('static let bg',1)[0]
        self.assertIn('traits.userInterfaceStyle == .dark ? dark : light',provider)
        for unsafe in ['MainActor','ThemeFontManager','SettingsStore','Task {','DispatchQueue']:
            self.assertNotIn(unsafe,provider)
        self.assertNotIn('SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated',
            (ROOT/'project.yml').read_text().split('targets:',1)[0])
    def test_normal_shake_preserves_mode_and_explicit_discovery_still_changes_it(self):
        home=(ROOT/'Sonivo/SonivoHomeRedesignedView.swift').read_text()
        manager=(ROOT/'Sonivo/AntigravityTransitionManager.swift').read_text()
        self.assertIn('triggerShakeWave(forceDiscover: Bool = false)',home)
        self.assertIn('triggerShift(forceDiscover: Bool = false)',manager)
        self.assertIn('triggerShakeWave(forceDiscover: true)',home)
        self.assertIn('if forceDiscover {\n                    waveStore.diversity = .discover',manager)
        self.assertNotIn('forceDiscover || waveStore.diversity != .discover',home+manager)
        shift=manager.split('func triggerShift',1)[1]
        self.assertNotIn('waveStore.language =',shift)
        self.assertNotIn('waveStore.moodEnergy =',shift)
    def test_shake_hud_describes_selected_settings_not_always_discovery(self):
        home=(ROOT/'Sonivo/SonivoHomeRedesignedView.swift').read_text()
        hud=home.split('// The explicit discovery card',1)[1].split('// Proximity sensor',1)[0]
        self.assertIn('forceDiscover ? WaveDiversity.discover : waveStore.diversity',hud)
        for key in ['diversity.title','waveStore.language.title','waveStore.moodEnergy.title']:
            self.assertIn(key,hud)
        self.assertNotIn('Свежие треки в «Незнакомом»',hud)
if __name__=='__main__': unittest.main()
