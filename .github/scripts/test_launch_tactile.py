"""Regression guards for the approved intact close-up reveal and bounded tactile cues."""
from pathlib import Path
import base64,json,hashlib,struct,unittest
R=Path(__file__).resolve().parents[2]
class LaunchTactileTests(unittest.TestCase):
    def test_shared_timeline_uses_medium_transients_without_continuous_bodies(self):
        motion=(R/'Sonivo/SonivoBrandLaunchMotion.swift').read_text()
        host=(R/'Sonivo/SonivoLaunchIntro.swift').read_text()
        self.assertIn('hapticOnsets: [Double] = [0.82, 1.46, 1.72].map { $0 / playbackRate }',motion)
        self.assertIn('hapticStrengths: [Float] = [0.50, 0.70, 0.55]',motion)
        for token in ['SettingsStore.shared.hapticsEnabled','supportsHaptics','engine.playsHapticsOnly = true',
                      'CHHapticTimeImmediate','CHHapticPattern(events: events, parameters: [])',
                      'CACurrentMediaTime() + lead', 'engine.currentTime + lead']:
            self.assertIn(token,host)
        for token in ['.hapticContinuous','AVAudioSession','MusicHapticsManager','repeatForever','Timer.']:
            self.assertNotIn(token,host)
        self.assertIn('if !enabled { haptics.stop() }',host)
    def test_full_display_surface_keeps_original_brand_vectors_and_tagline(self):
        host=(R/'Sonivo/SonivoLaunchIntro.swift').read_text()
        scene=(R/'Sonivo/SonivoBrandLaunchScene.swift').read_text()
        self.assertIn('.clipped()\n        .ignoresSafeArea(.container, edges: .all)',host)
        self.assertIn('Text("Музыка, которую чувствуешь.")',scene)
        self.assertIn('SonivoLaunchNameShape()',scene)
        self.assertNotIn('UIScreen.main.bounds',host)
        self.assertNotIn('.statusBarHidden',host)
    def test_material_is_offline_with_alpha_and_not_a_video_player(self):
        data=base64.b64decode((R/'design/resonance/generated/ResonanceLaunchLogo.png.b64').read_text().strip(),validate=True)
        self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
        self.assertEqual(struct.unpack('>IIBB',data[16:26]),(640,640,8,6))
        logo=(R/'Sonivo/SonivoResonanceSymbol.swift').read_text()
        self.assertIn('Image("ResonanceLaunchLogo")',logo)
        for bad in ['AVPlayer','URLSession','Data(base64Encoded:', 'GeometryReader']:
            self.assertNotIn(bad,logo)
        self.assertIn('!reduceMotion && time < 1.95',logo)
    def test_motion_blur_samples_the_scale_trajectory_not_static_gaussian_defocus(self):
        shader=(R/'Sonivo/SonivoLaunchRadialExposure.metal').read_text()
        self.assertIn('SwiftUI::Layer layer',shader)
        self.assertIn('constexpr int count=24',shader)
        self.assertIn('current/max(sampled,0.01f)',shader)
        self.assertIn('layer.sample(sourcePosition)',shader)
        self.assertNotIn('gaussian(',shader.lower())
        for token in ['1.12f','1.53f','3.0f','1.95f']:
            self.assertIn(token,shader)
    def test_uppercase_brand_glyphs_are_recorded_and_rendered(self):
        word=(R/'Sonivo/SonivoLaunchWordmark.swift').read_text()
        self.assertIn('Text("SONIVO")',word)
        p=json.loads((R/'docs/launch-font-provenance.json').read_text())
        self.assertTrue(set('SONIVO').issubset(set(p['glyph_text'])))
    def test_uiux_install_is_pinned_offline_guidance_not_native_runtime(self):
        lock=json.loads((R/'agent_skills/ui-ux-pro-max.lock.json').read_text())
        self.assertEqual(lock['repository'],'nextlevelbuilder/ui-ux-pro-max-skill')
        self.assertEqual(len(lock['commit']),40)
        self.assertEqual(len(lock['archive_sha256']),64)
        installer=(R/'scripts/install_uiux_skill.py').read_text()
        self.assertNotIn('subprocess',installer)
        self.assertIn('Archive mismatch',installer)
        self.assertNotIn('install_uiux_skill',(R/'project.yml').read_text())
if __name__=='__main__':unittest.main()
