"""Player interaction safety source contracts plus real Swift policy fixtures in macOS CI."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[2]
SCREEN=(R/'Sonivo/PlayerScreenV2.swift').read_text()
class PlayerIntentTests(unittest.TestCase):
    def test_cover_switch_requires_real_travel_not_predicted_speed(self):
        cover=SCREEN.split('private func artworkStage',1)[1].split('private func inlineLyricsStage',1)[0]
        self.assertIn('PlayerInteractionPolicy.trackDirection',cover)
        self.assertNotIn('predictedEndTranslation',cover)
        self.assertIn('!isCoverSwitching',cover)
        self.assertIn('animateTrackSwipe(direction: direction, width: width)',cover)
    def test_staged_swipe_is_cancelled_and_generation_protected(self):
        block=SCREEN.split('private func animateTrackSwipe',1)[1].split('private func releaseCoverSwitchLock',1)[0]
        for token in ['coverSwitchTask?.cancel()', 'coverSwitchGeneration == generation', '!Task.isCancelled', 'reduceMotion', '.easeIn(duration: 0.18)', '.spring(response: 0.42']:
            self.assertIn(token,block)
        lifetime=SCREEN.split('.onDisappear {',1)[1].split('private var isFullScreenVideoShot',1)[0]
        self.assertIn('coverSwitchTask?.cancel()',lifetime)
    def test_timeline_ignores_taps_and_vertical_drags_and_stale_track(self):
        block=SCREEN.split('struct PlayerTimelineSection',1)[1].split('final class SystemVolumeManager',1)[0]
        for token in [
            'DragGesture(minimumDistance: 10)',
            'PlayerInteractionPolicy.horizontalIntent',
            'scrubTrackID == (player.displayTrack?.id ?? player.currentTrack?.id)',
            'guard !mixing, isScrubbing, !scrubRejected',
            'start: scrubStartFraction',
            '.accessibilityAdjustableAction',
            '.onChange(of: scrubContact)',
            'Scrubber disabled while Automix',
        ]:
            self.assertIn(token,block)
        self.assertNotIn('value.location.x',block)
    def test_only_headers_allow_intentional_dismiss_drag(self):
        header=SCREEN.split('private var headerCloseGesture',1)[1].split('private func lyricsPlayerLayout',1)[0]
        self.assertIn('PlayerDismissPolicy.shouldClose',header)
        self.assertEqual(SCREEN.count('.simultaneousGesture(headerCloseGesture)'),2)
        policy=(R/'Sonivo/PlayerDismissPolicy.swift').read_text()
        self.assertIn('y >= 120',policy)
        self.assertNotIn('predictedY >',policy)
    def test_background_is_one_cover_area_color_without_saturation_weight(self):
        block=SCREEN.split('private var background:',1)[1].split('private var topHeader:',1)[0]
        self.assertIn('dominantArtworkColor',block)
        for token in ['RadialGradient','LinearGradient','palette.first']:
            self.assertNotIn(token,block)
        extraction=(R/'Sonivo/PlayerInteractionPolicy.swift').read_text().split('enum PlayerArtworkToneMath',1)[1]
        self.assertIn('bucket.weight += alpha',extraction)
        self.assertNotIn('saturation',extraction)
        self.assertIn('PlayerArtworkTone.extract(image)',SCREEN)
