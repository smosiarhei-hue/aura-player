"""Guards for native EQ usability and truthful playback-buffer presentation."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[2]


class EQRedesignAndBufferingTests(unittest.TestCase):
    def test_buffer_percentage_is_not_a_saved_download(self):
        source=(ROOT/'Sonivo/ActivePlayerPresentation.swift').read_text()
        block=source.split('var bufferedProgress:',1)[1].split('var queue:',1)[0]
        self.assertIn('legacy.usesStreamingBackend',block)
        self.assertNotIn('streamBufferFraction < 0.99',source)
        self.assertNotIn('var isDownloading:',source)
        self.assertIn('legacy.isPlaying && legacy.isStreamBuffering',block)

    def test_mini_player_does_not_replace_artist_for_background_prefetch(self):
        source=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        mini=source.split('struct NativeMiniPlayer:',1)[1].split('struct MiniPlayerArtwork:',1)[0]
        for wrong in ['Загрузка трека','Подготовка полного трека','downloadProgress','isDownloading','.disabled(isLoading)']:
            self.assertNotIn(wrong,mini)
        self.assertIn('showsWaitingStatus && isWaitingForAudio',mini)
        self.assertIn('Буферизация…',mini)
        self.assertIn('milliseconds(600)',mini)
        self.assertIn('return track?.artist',mini)
        self.assertIn('ProgressView(value: playbackFraction)',mini)

    def test_waiting_state_comes_from_audible_avplayer(self):
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertIn('p.observe(\\.timeControlStatus',core)
        self.assertIn('source === self.activeStreamingPlayer',core)
        self.assertIn('source.timeControlStatus == .waitingToPlayAtSpecifiedRate',core)
        self.assertIn('streamStatusObservers.removeAll()',core)

    def test_eq_uses_native_controls_with_large_targets_and_adaptive_text(self):
        source=(ROOT/'Sonivo/playerchrome.swift').read_text()
        eq=source.split('struct PlayerEQSheetView:',1)[1].split('struct TactileButtonStyle:',1)[0]
        self.assertIn('Slider(value: Binding(',eq)
        self.assertIn('step: 0.5',eq)
        self.assertIn('.frame(minHeight: 44)',eq)
        self.assertIn('ViewThatFits',eq)
        self.assertIn('dynamicTypeSize.isAccessibilitySize',eq)
        self.assertIn('.accessibilityValue(db(gain))',eq)
        self.assertIn('accessibilityReduceMotion',eq)
        self.assertNotIn('EQVerticalFader',source)
        self.assertNotIn('АЧХ ФИЛЬТРА',source)
        self.assertNotIn('.minimumScaleFactor',eq)

    def test_profiles_are_explicit_not_a_fake_device_calibration(self):
        source=(ROOT/'Sonivo/playerchrome.swift').read_text()
        self.assertIn('не калибровка Apple',source)
        self.assertIn('Точная нижняя граница не заявлена Apple',source)
        self.assertIn('Бас начинается с посадки',source)
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertIn('never overwrite a custom curve',core)
        self.assertIn('eq.bassProfiles.v3',core)
