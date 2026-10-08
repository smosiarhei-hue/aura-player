from pathlib import Path
import re
import unittest
ROOT=Path(__file__).resolve().parents[2]
class LinearEQTests(unittest.TestCase):
    def test_native_and_streaming_frequency_constants_match(self):
        swift=(ROOT/'Sonivo/playercore.swift').read_text()
        c=(ROOT/'Packages/StreamAudioProbe/Sources/StreamAudioProbe/RealtimeEQ.c').read_text()
        a=[float(x) for x in re.search(r'bandFrequencies: \[Float\] = \[([^]]+)\]',swift)[1].split(',')]
        b=[float(x) for x in re.search(r'frequencies\[SONIVO_EQ_BANDS\] = \{([^}]+)\}',c)[1].split(',')]
        self.assertEqual(a,b);self.assertEqual(len(a),10)
        self.assertEqual((a[0],a[-1]),(30,20000))
        self.assertIn('validRate * 0.44',swift)
        self.assertIn('rate * 0.44',c)
    def test_linear_native_sliders_and_accessibility_rows(self):
        text=(ROOT/'Sonivo/playerchrome.swift').read_text().split('struct PlayerEQSheetView:',1)[1]
        self.assertNotIn('EQRegion',text)
        self.assertIn('ScrollView(.horizontal)',text)
        self.assertIn('ForEach(0..<10',text)
        self.assertIn('dynamicTypeSize.isAccessibilitySize',text)
        self.assertIn('.rotationEffect(.degrees(-90))',text)
        self.assertIn('bandRow(index)',text)
        self.assertIn('20 кГц — номинальная',text)
    def test_named_presets_have_native_save_apply_and_confirmed_delete(self):
        ui=(ROOT/'Sonivo/playerchrome.swift').read_text()
        for expected in ['TextField("Название"','try userPresets.save(','player.eqGains = preset.gains','.confirmationDialog("Удалить пресет?"','try userPresets.delete(']:
            self.assertIn(expected,ui)
        store=(ROOT/'Sonivo/EQUserPresetStore.swift').read_text()
        for expected in ['JSONEncoder','JSONDecoder','eq.userPresets.v1','gains.count == 10','$0.isFinite','duplicateName','archiveIsValid','presets = next']:
            self.assertIn(expected,store)
        compiled=(ROOT/'.github/scripts/check_eq_user_presets.py').read_text()
        for expected in ['reloaded.presets==[saved]','reloaded.delete','broken archive','.nan','.infinity','bad count']:
            self.assertIn(expected,compiled)
if __name__=='__main__':unittest.main()
