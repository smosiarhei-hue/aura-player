"""Source guards and numerical checks for ribbon phase/envelope design.

Numerical checks mirror the equations; only Xcode/device tests validate Swift/Metal runtime.
"""
import math
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = (ROOT / 'Sonivo/MusicWaveBackground.swift').read_text()
METAL = (ROOT / 'Sonivo/BeatWave.metal').read_text()
MOTION = (ROOT / 'Sonivo/BeatWaveMotion.swift').read_text()
RENDERER = (ROOT / 'Sonivo/BeatWaveMetalView.swift').read_text()
HOME = (ROOT / 'Sonivo/SonivoHomeRedesignedView.swift').read_text()
HERO = (ROOT / 'Sonivo/MyWaveHeroView.swift').read_text()


def advance(state, dt, value, kick, fresh=True):
    phase, energy, impact, speed = state
    dt = max(0, min(.1, dt))
    target_energy = value if fresh else 0
    target_impact = kick if fresh else 0
    energy += (target_energy-energy)*(1-math.exp(-dt/(.08 if target_energy>energy else (.45 if fresh else .20))))
    impact += (target_impact-impact)*(1-math.exp(-dt/(.025 if target_impact>impact else (.38 if fresh else .15))))
    target_speed = .07+energy*.55+impact*.28 if fresh and target_energy>.003 else 0
    speed += (target_speed-speed)*(1-math.exp(-dt/(.06 if target_speed>speed else (.65 if fresh else .20))))
    return phase+dt*speed, energy, impact, speed


class MusicWaveTests(unittest.TestCase):
    def test_new_wave_replaces_home_burst(self):
        self.assertEqual(HOME.count('MusicWaveBackground('), 1)
        self.assertNotIn('PrismaticBurstBackground(', HOME)
        self.assertIn('fragment float4 beatWaveField', METAL)
        self.assertIn('BeatWaveMetalView(', SWIFT)

    def test_audio_changes_integrated_speed_not_absolute_time(self):
        self.assertIn('phase += Double(dt * speed)', MOTION)
        self.assertIn('energy*0.55+impact*0.28', MOTION)
        self.assertIn('frame.highs', MOTION)
        self.assertIn('frame.rms', MOTION)
        for fake in ['dynamicKick', 'dynamicBass', '120.0', 'player.progress']:
            self.assertNotIn(fake, SWIFT)

    def test_envelopes_are_finite_and_frame_rate_independent(self):
        self.assertIn('nonisolated struct MusicWaveMotion', MOTION)
        self.assertIn('delta.isFinite', MOTION)
        self.assertIn('value.isFinite', MOTION)
        self.assertIn('1-exp(-dt', MOTION)
        self.assertIn('max(0, min(0.1, delta))', MOTION)

    def test_edges_are_feathered_and_no_opaque_black_panel(self):
        self.assertIn('float featherX = smoothstep', METAL)
        self.assertIn('float featherY = smoothstep', METAL)
        self.assertIn('rgb * alpha', METAL)
        self.assertIn('view.isOpaque=false', RENDERER)
        self.assertNotIn('glassHalfSize', METAL)
        self.assertNotIn('.mask {', SWIFT)
        wave = HOME.split('private var waveHero:', 1)[1].split('private var quickDestinations:', 1)[0]
        self.assertIn('SN.bg', wave)
        self.assertNotIn('Color.black', wave)
        self.assertNotIn('.environment(\\.colorScheme, .dark)', wave)
        self.assertNotIn('.foregroundStyle(Color.white', HERO)

    def test_wave_has_no_grain_raymarch_or_strobe(self):
        self.assertIn('i < 32', METAL)
        self.assertIn('float coreEnergy', METAL)
        for heavy in ['marchT', 'prismaticNoise', 'random', 'i < 44']:
            self.assertNotIn(heavy, METAL)

    def test_lifecycle_and_reduce_motion_stop_motion(self):
        self.assertIn('!reduceMotion && scenePhase == .active', SWIFT)
        self.assertIn('guard running else { stop(); return }', RENDERER)
        self.assertIn('presentation.reset(); motion.settle()', RENDERER)
        self.assertIn('age<outputDelay+0.4', RENDERER)
        self.assertIn('.allowsHitTesting(false)', SWIFT)
        self.assertIn('.accessibilityHidden(true)', SWIFT)

    def test_stronger_music_increases_speed_without_phase_jumps(self):
        quiet = loud = (0., 0., 0., 0.)
        for _ in range(90):
            quiet = advance(quiet, 1/30, .08, 0)
            loud = advance(loud, 1/30, .70, .8)
        self.assertGreater(loud[3], quiet[3]*3)
        before = loud[0]
        after = advance(loud, 1/30, .1, 0)
        self.assertGreaterEqual(after[0], before)
        self.assertLess(after[0]-before, .1)

    def test_no_audio_settles_instead_of_inventing_a_beat(self):
        state = (0.,0.,0.,0.)
        for _ in range(60): state = advance(state, 1/30, .7, .6)
        for _ in range(150): state = advance(state, 1/30, 0, 0, False)
        self.assertLess(state[1], .00001)
        self.assertLess(state[3], .0001)

    def test_similar_phase_at_twenty_thirty_and_sixty_fps(self):
        phases = []
        for fps in (20,30,60):
            state = (0.,0.,0.,0.)
            for _ in range(fps*4): state = advance(state, 1/fps, .6, .3)
            phases.append(state[0])
        self.assertLess(max(phases)-min(phases), .08)

if __name__ == '__main__': unittest.main()
