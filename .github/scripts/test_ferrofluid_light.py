"""Cosmetic light guards; actual Swift envelope is exercised by the existing macOS test."""
import math
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
METAL=(ROOT/'Sonivo/BeatWave.metal').read_text()
RENDERER=(ROOT/'Sonivo/BeatWaveMetalView.swift').read_text()
class FerrofluidLightTests(unittest.TestCase):
    def test_bright_rims_only_and_audio_channels_not_wall_clock(self):
        pulse=METAL.split('float ferroLightPulse',1)[1].split('float4 evalFerrofluid',1)[0]
        self.assertIn('uBassLight',pulse); self.assertIn('uKickLight',pulse)
        for unwanted in ['uDetail','uEnergy','uPhase','sin(','cos(']: self.assertNotIn(unwanted,pulse)
        self.assertIn('hotspot=smoothstep(0.18,1.10,ltn)',METAL)
        self.assertIn('hotspot*ferroLightPulse(u)*0.85',METAL)
        self.assertEqual(METAL.count('fragment float4'),1)
    def test_cosmetic_uniforms_and_reset_without_changing_motion_input(self):
        self.assertIn('highlight.bass,highlight.kick',RENDERER)
        self.assertIn('#define uBassLight u.resolution.z',METAL)
        self.assertIn('#define uKickLight u.resolution.w',METAL)
        self.assertIn('highlight.advance(delta: dt,bass: motion.lowEnergy,kick: motion.impact)',RENDERER)
        self.assertIn('motion.settle(); highlight.reset()',RENDERER)
        self.assertNotIn('highlight', (ROOT/'Sonivo/BeatWaveMotion.swift').read_text())
    def test_smooth_light_rise_and_frame_rate_independence(self):
        def advance(value,target,dt):
            return value+(target-value)*(1-math.exp(-dt/(.018 if target>value else .22)))
        first=advance(0,1,1/120)
        self.assertGreater(first,0); self.assertLess(first,1)
        tails=[]
        for fps in [30,60,120]:
            value=0
            for _ in range(fps): value=advance(value,.8,1/fps)
            for _ in range(fps//2): value=advance(value,0,1/fps)
            tails.append(value)
        self.assertLess(max(tails)-min(tails),1e-12)
        self.assertIn('k>kick ? 0.018 : 0.22',RENDERER)
    def test_edr_gain_within_available_headroom_and_sdr_hue_preserved(self):
        self.assertIn('musicalHeadroom=0.35+ferroLightPulse(u)*0.65',METAL)
        self.assertIn('(1.0-exp(-sdrPeak*1.25))/sdrPeak',METAL)
        self.assertIn('rgb=clamp(rgb,0.0,max(1.0,u.display.x))',METAL)
        for headroom in [1,1.2,2,2.5]:
            for pulse in [0,.2,.6,1]:
                for mask in [0,.4,1]:
                    gain=1+(headroom-1)*mask*(.35+pulse*.65)
                    self.assertGreaterEqual(gain,1);self.assertLessEqual(gain,headroom+1e-12)
        rgb=[2,.6,.2]; scaled=[x*(1-math.exp(-max(rgb)*1.25))/max(rgb) for x in rgb]
        self.assertAlmostEqual(scaled[0]/scaled[1],rgb[0]/rgb[1])
if __name__=='__main__': unittest.main()
