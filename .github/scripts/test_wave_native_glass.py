"""Keep clean artwork and native, localized Liquid Glass; never blur the music field."""
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class NativeWaveGlassTests(unittest.TestCase):
    def test_cover_has_no_accent_or_black_shadow_halo(self):
        s=(ROOT/'Sonivo/MyWaveHeroView.swift').read_text()
        stage=s.split('private var centralVisualStage:',1)[1].split('// MARK: - Track Metadata',1)[0]
        self.assertNotIn('.shadow(',stage)
        self.assertNotIn('.blur(',stage)
        self.assertNotIn('.glassEffect',stage)
        for artwork in ['RemoteArtwork(urlString: cover, corner: 26)','SmallArtwork(track: track, size: 220)']:
            self.assertIn(artwork,stage)
        self.assertIn('.buttonStyle(TactileButtonStyle(scale: 0.97))',stage)
        self.assertIn('showPlayer = true',stage)
    def test_controls_use_single_native_effect_and_container(self):
        s=(ROOT/'Sonivo/MyWaveHeroView.swift').read_text()
        header=s.split('private var headerBar:',1)[1].split('// MARK: - Central Living',1)[0]
        self.assertIn('GlassEffectContainer(spacing: 8)',header)
        self.assertEqual(header.count('.glassCircle(interactive: true)'),2)
        self.assertNotIn('Material',header)
        self.assertNotIn('.blur(',header)
        self.assertNotIn('.tint(',header)
        filters=s.split('private var bottomSparklesAndChips:',1)[1].split('// MARK: - Swipe Gesture',1)[0]
        self.assertIn('.glassCapsule(interactive: true)',filters)
        self.assertNotIn('ultraThinMaterial',filters)
        self.assertNotIn('strokeBorder',filters)
        self.assertIn('reduceMotion ? nil',filters)
    def test_native_blur_is_background_only_and_theme_aware(self):
        theme=(ROOT/'Sonivo/theme.swift').read_text()
        wrappers=theme.split('// MARK: - Liquid Glass surfaces',1)[1].split('struct GlassIconButton',1)[0]
        self.assertIn('.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)',wrappers)
        self.assertIn('.glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)',wrappers)
        wave=(ROOT/'Sonivo/MusicWaveBackground.swift').read_text()
        home=(ROOT/'Sonivo/SonivoHomeRedesignedView.swift').read_text()
        self.assertNotIn('.blur(',wave)
        self.assertNotIn('Material',wave)
        self.assertIn('height: hero.size.height+waveTopInset',home)
        self.assertIn('.offset(y: -waveTopInset)',home)
        self.assertIn('isVisible: waveHeroIsVisible',home)
        self.assertEqual(home.count('MusicWaveBackground('),1)
if __name__=='__main__': unittest.main()
