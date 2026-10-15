"""Source-contract checks. Native shader/Swift compilation is the Xcode CI gate."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class LiquidMetalTests(unittest.TestCase):
    def test_native_shader_is_pinned_and_licensed(self):
        s=(ROOT/'Sonivo/SonivoLiquidMetal.metal').read_text()
        self.assertIn('bfcb86329da15235a5ee2dcdb6417c8a80f82bb1',s)
        self.assertIn('[[ stitchable ]] half4 sonivoLiquidMetal',s)
        self.assertIn('Apache-2.0',s)
        self.assertIn('float4 bounds',s)
        self.assertIn('max(bounds.zw, float2(1.0))',s)
        self.assertIn('.boundingRect',(ROOT/'Sonivo/SonivoMetalSurface.swift').read_text())
        self.assertIn('Copyright (c) 2026 Jakub Antalik',(ROOT/'Sonivo/Resources/Licenses/MetalFxKit.txt').read_text())
        self.assertIn('Apache License',(ROOT/'Sonivo/Resources/Licenses/Paper-Shaders.txt').read_text())
    def test_animation_has_one_explicit_opt_in(self):
        s=(ROOT/'Sonivo/SonivoMetalSurface.swift').read_text()
        self.assertEqual(s.count('TimelineView('),1)
        self.assertIn('if canRender {\n                if animated {',s)
        self.assertIn('minimumInterval: 1.0 / 30.0',s)
        self.assertNotIn('paused: false',s)
        self.assertNotIn('truncatingRemainder',s)
        sites=[]
        for p in (ROOT/'Sonivo').glob('*.swift'):
            for line in p.read_text().splitlines():
                if '.sonivoMetal(' in line and 'animated:' in line: sites.append((p.name,line))
        self.assertEqual(len(sites),1)
        self.assertEqual(sites[0][0],'PlayerScreenV2.swift')
        self.assertIn('animated: player.isPlaying',sites[0][1])
    def test_fallback_removes_shader_and_clocks(self):
        s=(ROOT/'Sonivo/SonivoMetalSurface.swift').read_text()
        for token in ['scenePhase == .active','!constrained','!reduceMotion','!reduceTransparency',
                      'contrast != .increased','isEnabled','isLowPowerModeEnabled','.serious','.critical',
                      '.NSProcessInfoPowerStateDidChange','ProcessInfo.thermalStateDidChangeNotification']:
            self.assertIn(token,s)
        self.assertIn('.allowsHitTesting(false)',s)
        self.assertIn('.accessibilityHidden(true)',s)
        for token in ['CoreMotion','CMMotionManager','GeometryReader','Timer.publish','WKWebView']:
            self.assertNotIn(token,s)
    def test_shared_controls_and_opt_out(self):
        s=(ROOT/'Sonivo/theme.swift').read_text().split('extension View {',1)[1].split('struct GlassIconButton',1)[0]
        self.assertEqual(s.count('.sonivoMetal('),4)
        self.assertEqual(s.count('.glassEffect('),4)
        settings=(ROOT/'Sonivo/SonivoAppearanceView.swift').read_text()
        self.assertIn('@AppStorage(SonivoMetalSurface.enabledKey)',settings)
        self.assertIn('isOn: $liquidMetalEnabled',settings)
        self.assertIn('.sonivoMetal(corner: SN.radiusSmall',(ROOT/'Sonivo/SettingsUI.swift').read_text())
    def test_existing_player_semantics_survive(self):
        s=(ROOT/'Sonivo/PlayerScreenV2.swift').read_text()
        for token in ['Button(action: togglePlayback)','Button(action: previousTrack)',
                      'Button(action: nextTrack)', '.disabled(player.isLoading)',
                      '.regular.tint(glassTint).interactive()', 'SonivoEqualizerGlyph(']:
            self.assertIn(token,s)
        self.assertNotIn('sonivoMetal',(ROOT/'SonivoLiveActivity/SonivoLiveActivityWidget.swift').read_text())
        lifecycle=(ROOT/'Sonivo/SonivoCaptureBrand.swift').read_text()
        self.assertNotIn('safeAreaInset',lifecycle)
if __name__=='__main__': unittest.main()
