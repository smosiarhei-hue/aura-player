"""Unified text UX and native compositor motion must not alter source timing."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class LyricsPresentationMotionTests(unittest.TestCase):
    def test_all_open_close_actions_share_accessible_motion(self):
        player = (ROOT/'Sonivo/PlayerScreenV2.swift').read_text()
        self.assertEqual(player.count('withAnimation(LyricsPresentationMotion.animation(reduceMotion: reduceMotion)) { showLyricsMode'), 3)
        self.assertEqual(player.count('.transition(LyricsPresentationMotion.transition(reduceMotion: reduceMotion))'), 2)
        self.assertNotIn('.animation(SN.slowSpring, value: showLyricsMode)', player)
        self.assertIn('.animation(LyricsPresentationMotion.controlsAnimation(reduceMotion: reduceMotion), value: lyricsControlsVisible)', player)
        self.assertIn('Label("Закрыть текст"', player)
        self.assertIn('Label("Показать управление"', player)

    def test_native_motion_has_no_timer_or_word_delay(self):
        source = (ROOT/'Sonivo/LyricsPresentationMotion.swift').read_text()
        for value in ['.smooth(duration: 0.38, extraBounce: 0)', '.smooth(duration: 0.30, extraBounce: 0)', 'reduceMotion ? nil', 'reduceMotion ? .identity', '.offset(y: 16)']:
            self.assertIn(value, source)
        for forbidden in ['Timer(', 'Task.sleep', 'asyncAfter', 'frameTime', 'player.seek', 'TimelineView']:
            self.assertNotIn(forbidden, source)
        project = (ROOT/'project.yml').read_text()
        self.assertIn('CADisableMinimumFrameDurationOnPhone: true', project)
        clock = (ROOT/'Sonivo/LyricsDisplayClock.swift').read_text()
        for value in ['screen.maximumFramesPerSecond', 'preferredFrameRateRange', 'frameLimit = 120', 'forMode: .common']:
            self.assertIn(value, clock)

    def test_mode_and_inline_size_menus_are_gone(self):
        source = (ROOT/'Sonivo/TypographyLyricsView.swift').read_text()
        self.assertNotIn('Picker(', source)
        self.assertNotIn('Text("Aa")', source)
        self.assertNotIn('LyricsTypographyModeBar', source)
        self.assertIn('KaraokeTypography.font(size: fontSize)', source)
        self.assertIn('.transaction { $0.animation = nil }', source)
