"""Regression guards for miniature artwork and non-darkening fullscreen shader."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MiniArtworkAndShaderBlendTests(unittest.TestCase):
    def test_mini_artwork_has_one_stable_frame_and_clip(self):
        source = (ROOT / 'Sonivo/sonivoapp.swift').read_text()
        artwork = source.split('struct MiniPlayerArtwork: View', 1)[1].split('// MARK:', 1)[0]
        self.assertIn('private let side: CGFloat = 44', artwork)
        self.assertIn('.scaledToFit()', artwork)
        self.assertIn('.fixedSize()', artwork)
        self.assertEqual(artwork.count('.clipShape('), 1)
        for modifier in ('.scaleEffect(', '.animation(', '.strokeBorder(', 'ScaledMetric'):
            self.assertNotIn(modifier, artwork)
        self.assertNotIn('MiniArtworkPulse', source)

    def test_cached_remote_and_placeholder_artwork_remain_supported(self):
        source = (ROOT / 'Sonivo/sonivoapp.swift').read_text()
        self.assertIn('LibraryStore.cachedArtworkImage(for: track)', source)
        self.assertIn('AsyncImage(url: url)', source)
        self.assertIn('.id(track?.id)', source)
        self.assertIn('MiniPlayerArtwork(track: track)', source)
        self.assertIn('.matchedTransitionSource(id: RootView.playerZoomID', source)
        self.assertIn('.padding(.leading, 14)', source)

    def test_shader_is_transparent_and_uses_light_only_blend(self):
        view = (ROOT / 'Sonivo/WaveShakeOverlayView.swift').read_text()
        metal = (ROOT / 'Sonivo/AntigravityVortex.metal').read_text()
        self.assertIn('.blendMode(.screen)', view)
        self.assertNotIn('Color.black', view)
        self.assertIn('Color.clear', view)
        self.assertIn('color * glowAlpha', metal)
        self.assertIn('half(glowAlpha)', metal)
        self.assertNotIn('return half4(half3(color), 1.0h)', metal)

    def test_screen_blending_cannot_reduce_background_brightness(self):
        # Reference screen blending: alpha-weighted result must be >= destination
        # for all valid RGB channels, including transparent and black ring gaps.
        for background in [0, .05, .25, .5, .9, 1]:
            for glow in [0, .1, .5, 1]:
                for alpha in [0, .1, .5, 1]:
                    screen = 1 - (1 - background) * (1 - glow)
                    result = screen * alpha + background * (1 - alpha)
                    self.assertGreaterEqual(result + 1e-12, background)
                    self.assertLessEqual(result, 1 + 1e-12)


if __name__ == '__main__':
    unittest.main()
