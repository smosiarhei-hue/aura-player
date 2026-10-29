from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LinearEQTests(unittest.TestCase):
    def test_native_and_streaming_frequency_constants_match(self):
        swift=(ROOT/'Sonivo/EQGainLimits.swift').read_text()
        c=(ROOT/'Packages/StreamAudioProbe/Sources/StreamAudioProbe/RealtimeEQ.c').read_text()
        a=[float(x) for x in re.search(r'frequencies: \[Float\] = \[([^]]+)\]',swift)[1].split(',')]
        b=[float(x) for x in re.search(r'frequencies\[SONIVO_EQ_BANDS\] = \{([^}]+)\}',c)[1].split(',')]
        self.assertEqual(a,b);self.assertEqual(a,[60,120,400,1000,2400,15000])
        self.assertEqual((a[0],a[-1]),(60,15000))
        self.assertIn('validRate * 0.44',(ROOT/'Sonivo/playercore.swift').read_text())
        self.assertIn('rate * 0.44',c)
        dual=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift').read_text()
        d=[float(x) for x in re.search(r'let frequencies: \[Float\] = \[([^]]+)',dual)[1].split(',')]
        self.assertEqual(a,d)
        self.assertIn('numberOfBands: 6',dual)
        self.assertIn('bandwidth * w',c)
        self.assertIn('bandWidthOctaves',c)
        self.assertIn('EQGainLimits.bandwidth(at:i)',(ROOT/'Sonivo/playercore.swift').read_text())
        self.assertIn('case 0: return 0.55',(ROOT/'Sonivo/EQGainLimits.swift').read_text())
    def test_single_screen_graph_and_native_precise_slider(self):
        text=(ROOT/'Sonivo/playerchrome.swift').read_text().split('struct PlayerEQSheetView:',1)[1]
        self.assertNotIn('EQRegion',text)
        self.assertNotIn('ScrollView(.horizontal)',text)
        self.assertIn('ForEach(PlayerCore.bandFrequencies.indices',text)
        self.assertIn('dynamicTypeSize.isAccessibilitySize',text)
        self.assertIn('CompactEQCurve(gains:',text)
        self.assertIn('bandRow(selectedBand)',text)
        self.assertIn('count: EQGainLimits.frequencies.count',text)
        self.assertIn('minHeight: 44',text)
        self.assertIn('draggingBand = closest',text)
        self.assertIn('selectedBand = closest',text)
        self.assertIn('bandRow(index)',text)
        self.assertIn('15 кГц — номинальная',text)
    def test_named_presets_have_native_save_apply_and_confirmed_delete(self):
        ui=(ROOT/'Sonivo/playerchrome.swift').read_text()
        for expected in ['TextField("Название"','try userPresets.save(','player.eqGains = preset.gains','.confirmationDialog("Удалить пресет?"','try userPresets.delete(']:
            self.assertIn(expected,ui)
        store=(ROOT/'Sonivo/EQUserPresetStore.swift').read_text()
        for expected in ['JSONEncoder','JSONDecoder','eq.userPresets.v1','gains.count == EQGainLimits.frequencies.count','$0.element.isFinite','duplicateName','archiveIsValid','presets = next']:
            self.assertIn(expected,store)
        compiled=(ROOT/'.github/scripts/check_eq_user_presets.py').read_text()
        for expected in ['reloaded.presets==[saved]','reloaded.delete','broken archive','.nan','.infinity','bad count']:
            self.assertIn(expected,compiled)
if __name__=='__main__':unittest.main()
