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
        self.assertIn('eq->sampleRate*.035',c)
        self.assertIn('eq->sampleRate*.280',c)
    def test_native_envelopes_and_low_band_width_are_consistent(self):
        core=(R/'Sonivo/playercore.swift').read_text()
        dual=(R/'Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift').read_text()
        for text in [core,dual]:
            for value in ['kLimiterParam_AttackTime','kLimiterParam_DecayTime','kLimiterParam_PreGain','0.024','0.120']:
                self.assertIn(value,text)
        limits=(R/'Sonivo/EQGainLimits.swift').read_text()
        self.assertIn('case 0: return 0.55',limits)
        self.assertIn('case 1: return 0.70',limits)
        self.assertIn('[60, 120, 400, 1000, 2400, 15000]',limits)
        self.assertIn('0.55, 0.70, 0.90',dual)
        self.assertIn('EQGainLimits.bandwidth(at:0) == 0.55',(R/'.github/scripts/check_eq_user_presets.py').read_text())
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
                         'guard let index = hitBand(location, size: size)', 'onReset(index)', 'onEnd()']:
            self.assertIn(expected,ui)
        reset=ui.split('private func resetPoint(',1)[1].split('var body:',1)[0]
        self.assertNotIn('EQPresets.flat',reset)
        self.assertNotIn('for index',reset)
        fixture=(R/'.github/scripts/check_eq_user_presets.py').read_text()
        self.assertIn('graphHitBand(x:x,y:y',fixture)
        self.assertIn('graphHitBand(x:.nan',fixture)

    def test_six_band_reference_and_symmetric_gain_range_have_real_filters(self):
        limits=(R/'Sonivo/EQGainLimits.swift').read_text()
        header=(R/'Packages/StreamAudioProbe/Sources/StreamAudioProbe/RealtimeEQ.h').read_text()
        self.assertIn('[60, 120, 400, 1000, 2400, 15000]',limits)
        self.assertIn('static let maximum: Float = 15',limits)
        self.assertIn('-maximum...maximum',limits)
        self.assertIn('#define SONIVO_EQ_BANDS 6',header)
        self.assertIn('eq.gains.reference6.backup',(R/'Sonivo/playercore.swift').read_text())
        self.assertIn('eq.layout.bassTight6',(R/'Sonivo/playercore.swift').read_text())
        self.assertIn('eq.userPresets.reference6.backup',(R/'Sonivo/EQUserPresetStore.swift').read_text())
        self.assertIn('eq.userPresets.bassTight6.backup',(R/'Sonivo/EQUserPresetStore.swift').read_text())
    def test_manual_haptics_are_shared_by_graph_and_slider_and_obey_settings(self):
        ui=(R/'Sonivo/playerchrome.swift').read_text()
        self.assertIn('setBandGain(index, Float(value))',ui)
        self.assertIn('adjustmentFeedback.intensity(from: oldGain',ui)
        theme=(R/'Sonivo/theme.swift').read_text().split('static func eqAdjustment(',1)[1].split('static func success()',1)[0]
        self.assertIn('SettingsStore.shared.hapticsEnabled',theme)
        self.assertIn('impactOccurred(intensity:',theme)
        policy=(R/'Sonivo/EQAdjustmentFeedback.swift').read_text()
        self.assertIn('time - lastPulse >= 0.060',policy)
        self.assertIn('abs(gain) / EQGainLimits.maximum',policy)
        self.assertNotIn('PlayerCore',policy)
