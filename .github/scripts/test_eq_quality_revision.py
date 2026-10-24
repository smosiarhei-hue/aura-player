from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[2]
class EQQualityRevisionTests(unittest.TestCase):
    def test_gain_domain_smoothing_and_linked_peak_hold_are_realtime_safe(self):
        c=(R/'Packages/StreamAudioProbe/Sources/StreamAudioProbe/RealtimeEQ.c').read_text()
        render=c.split('void SonivoEQProcess(',1)[1]
        for expected in ['eq->targetDB[b]-eq->gainDB[b]','coefficients(b,eq->gainDB[b]','eq->peakHoldFrames','protectedWet*eq->wet']:
            self.assertIn(expected,render)
        for forbidden in ['malloc(', 'calloc(', 'realloc(', 'dispatch_', 'mutex', 'sleep(']:
            self.assertNotIn(forbidden,render)
        self.assertIn('eq->sampleRate*.050',c)
        self.assertIn('eq->sampleRate*.200',c)
    def test_native_envelopes_and_low_band_width_are_consistent(self):
        core=(R/'Sonivo/playercore.swift').read_text()
        dual=(R/'Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift').read_text()
        for text in [core,dual]:
            for value in ['kLimiterParam_AttackTime','kLimiterParam_DecayTime','kLimiterParam_PreGain','0.012','0.060']:
                self.assertIn(value,text)
        self.assertIn('band == 1 ? 0.75 : 1',(R/'Sonivo/EQGainLimits.swift').read_text())
        self.assertIn('index == 1 ? 0.75 : 1',dual)
        self.assertIn('EQGainLimits.bandwidth(at:1) == 0.75',(R/'.github/scripts/check_eq_user_presets.py').read_text())
    def test_geometry_animates_without_animating_the_audio_controls(self):
        shapes=(R/'Sonivo/EQResponseShapes.swift').read_text()
        ui=(R/'Sonivo/playerchrome.swift').read_text()
        self.assertIn('VectorArithmetic',shapes)
        self.assertIn('var animatableData: EQCurveVector',shapes)
        self.assertIn('SonivoStreamEQResponse(',shapes)
        for forbidden in ['PlayerCore','Task.sleep','Timer','CADisplayLink']:
            self.assertNotIn(forbidden,shapes)
        self.assertIn('isAdjustingEQ = editing',ui)
        self.assertIn('reduceMotion || isInteracting || draggingBand != nil ? nil',ui)
        self.assertIn('Суммарная АЧХ · модель PCM 48 кГц',ui)
        self.assertIn('не измерение наушников',ui)

    def test_double_tap_resets_only_hit_node_and_does_not_conflict_with_drag(self):
        ui=(R/'Sonivo/playerchrome.swift').read_text().split('private struct CompactEQCurve:',1)[1]
        for expected in ['SpatialTapGesture(count: 2)', '.exclusively(before: DragGesture(minimumDistance: 3)',
                         'guard let index = hitBand(location, size: size)', 'onChange(index, 0)', 'onEnd()']:
            self.assertIn(expected,ui)
        reset=ui.split('private func resetPoint(',1)[1].split('var body:',1)[0]
        self.assertNotIn('EQPresets.flat',reset)
        self.assertNotIn('for index',reset)
        fixture=(R/'.github/scripts/check_eq_user_presets.py').read_text()
        self.assertIn('graphHitBand(x:x,y:y',fixture)
        self.assertIn('graphHitBand(x:.nan',fixture)
