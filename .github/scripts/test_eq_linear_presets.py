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
        self.assertEqual(a,b);self.assertEqual(a,[32,64,125,250,500,1000,2000,4000,8000,16000])
        self.assertEqual((a[0],a[-1]),(32,16000))
        self.assertIn('validRate * 0.44',(ROOT/'Sonivo/playercore.swift').read_text())
        self.assertIn('rate * 0.44',c)
        dual=(ROOT/'Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift').read_text()
        d=[float(x) for x in re.search(r'let frequencies: \[Float\] = \[([^]]+)',dual)[1].split(',')]
        self.assertEqual(a,d)
        self.assertIn('numberOfBands: 10',dual)
        self.assertIn('numberOfBands: 6',dual)  # per-deck mashup FX stays 6-band
        self.assertIn('bandwidth * w',c)
        self.assertIn('bandWidthOctaves',c)
        self.assertIn('EQGainLimits.bandwidth(at:i)',(ROOT/'Sonivo/playercore.swift').read_text())
        self.assertIn('case 0: return 0.90',(ROOT/'Sonivo/EQGainLimits.swift').read_text())
        self.assertIn('case 1: return 0.85',(ROOT/'Sonivo/EQGainLimits.swift').read_text())
    def test_single_screen_direct_graph_controls(self):
        text=(ROOT/'Sonivo/PlayerEQSheetView.swift').read_text()
        self.assertIn('CompactEQCurve(',text)
        self.assertIn('dynamicTypeSize.isAccessibilitySize',text)
        self.assertNotIn('Slider(value:',text)
        self.assertNotIn('selectedBandPrecision',text)
        self.assertIn('draggingBand = closest',text)
        self.assertIn('selectedBand = closest',text)
        self.assertIn('dragOriginY = point(closest, size: size).y',text)
        self.assertIn('dragOriginY + value.translation.height',text)
        self.assertIn('onChange(index, rawGain)',text)
        self.assertIn('if draggingBand != nil { onEnd() }',text)
        self.assertIn('.accessibilityAdjustableAction',text)
        self.assertIn('onStep(index, 0.5)',text)
        self.assertIn('onStep(index, -0.5)',text)
        self.assertIn('[32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]',(ROOT/'Sonivo/EQGainLimits.swift').read_text())
    def test_named_presets_have_native_save_apply_and_confirmed_delete(self):
        ui=(ROOT/'Sonivo/PlayerEQSheetView.swift').read_text()
        for expected in ['TextField("Название"','try userPresets.save(','player.eqGains = preset.gains','.confirmationDialog("Удалить пресет?"','try userPresets.delete(']:
            self.assertIn(expected,ui)
        store=(ROOT/'Sonivo/EQUserPresetStore.swift').read_text()
        for expected in ['JSONEncoder','JSONDecoder','eq.userPresets.v1','gains.count == EQGainLimits.frequencies.count','$0.element.isFinite','duplicateName','archiveIsValid','presets = next']:
            self.assertIn(expected,store)
        compiled=(ROOT/'.github/scripts/check_eq_user_presets.py').read_text()
        for expected in ['reloaded.presets==[saved]','reloaded.delete','broken archive','.nan','.infinity','bad count']:
            self.assertIn(expected,compiled)
if __name__=='__main__':unittest.main()
