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

    def test_eq_uses_direct_graph_controls_and_adaptive_text(self):
        source=(ROOT/'Sonivo/PlayerEQSheetView.swift').read_text()
        eq=source.split('struct PlayerEQSheetView:',1)[1].split('struct CompactEQCurve:',1)[0]
        self.assertNotIn('Slider(value:',eq)
        self.assertIn('CompactEQCurve(',eq)
        self.assertIn('.frame(minHeight: 44)',eq)
        self.assertIn('ViewThatFits',eq)
        self.assertIn('dynamicTypeSize.isAccessibilitySize',eq)
        self.assertIn('.accessibilityAdjustableAction',source)
        self.assertIn('onStep(index, 0.5)',source)
        self.assertIn('accessibilityReduceMotion',eq)
        self.assertNotIn('EQVerticalFader',source)
        self.assertNotIn('АЧХ ФИЛЬТРА',source)
        self.assertNotIn('.minimumScaleFactor',eq)
        # Modern sheet: no marketing/dashboard card copy, no AirPods framing.
        self.assertNotIn('Твой звук',eq)
        self.assertNotIn('Выбери характер',eq)
        self.assertNotIn('AirPods',eq)
        self.assertIn('Пресеты',eq)
        self.assertIn('Только полосные фильтры',eq)

    def test_profiles_are_listening_tastes_not_device_calibration(self):
        source=(ROOT/'Sonivo/PlayerEQSheetView.swift').read_text()
        models=(ROOT/'Sonivo/models.swift').read_text()
        # Clear primary chip order; headphones taste is secondary / renamed.
        self.assertIn('EQPresets.flat, EQPresets.bassBoost, EQPresets.subBassPower, EQPresets.bassTrebleBoost',source)
        self.assertIn('EQPresets.classical, EQPresets.club, EQPresets.dance',source)
        self.assertIn('secondaryPresets',source)
        self.assertIn('EQPresets.airPodsPro2Bass',source)
        self.assertIn('name: "Наушники"',models)
        self.assertNotIn('AirPods Pro 2',models)
        self.assertNotIn('не калибровка Apple',source)
        self.assertNotIn('Точная нижняя граница не заявлена Apple',source)
        self.assertNotIn('Бас начинается с посадки',source)
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertIn('never overwrite a custom curve',core)
        self.assertIn('eq.bassProfiles.v3',core)


if __name__ == '__main__':
    unittest.main()
