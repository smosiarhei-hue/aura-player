"""Source integration guards and reference timing/tokenization math for the new design."""
import math
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def timing(count, available):
    count = max(1, count)
    budget = min(1.8, max(.12, available * .70))
    duration = min(.60, max(.12, budget * .55))
    delay = min(.08, max(0, budget - duration) / (count - 1)) if count > 1 else 0
    return duration, delay, duration + delay * (count - 1)


def segments(text):
    result, segment, last_space = [], '', False
    for char in text:
        if not char.isspace() and last_space and segment:
            result.append(segment)
            segment = ''
        segment += char
        last_space = char.isspace()
    if segment:
        result.append(segment)
    return result


class StaggeredLyricsDesignTests(unittest.TestCase):
    def test_legacy_preferences_migrate_to_standard_typography(self):
        text = (ROOT / 'Sonivo/theme.swift').read_text()
        self.assertIn('let lyricsDesign: LyricsDesign = .typography', text)
        self.assertIn('defaults.removeObject(forKey: "lyrics.design")', text)
        self.assertNotIn('defaults.set(lyricsDesign.rawValue', text)

    def test_settings_has_no_obsolete_mode_picker(self):
        text = (ROOT / 'Sonivo/settingsview.swift').read_text()
        self.assertNotIn('selection: $settings.lyricsDesign', text)
        self.assertNotIn('LyricsDesignPreview(', text)
        self.assertIn('$settings.lyricsFontSize', text)

    def test_all_visible_surfaces_use_standard_typography(self):
        for name in ['PlayerScreenV2.swift', 'lyricsview.swift']:
            text = (ROOT / 'Sonivo' / name).read_text()
            self.assertIn('TypographyLyricsView(lyrics: lyrics, player: player', text)
            self.assertNotIn('settings.lyricsDesign ==', text)
            self.assertNotIn('StaggeredLyricsView(lyrics: lyrics', text)
            self.assertNotIn('LyricsTypographyModeBar', text)

    def test_word_reveal_uses_native_text_layout_and_accessibility(self):
        text = (ROOT / 'Sonivo/StaggeredLyricsView.swift').read_text()
        self.assertIn('TextRenderer', text)
        self.assertIn('.customAttribute(StaggeredWordAttribute', text)
        self.assertIn('copy.translateBy', text)
        self.assertIn('.blur(radius:', text)
        self.assertIn('accessibilityReduceMotion', text)
        self.assertIn('reduceMotion || !isActive ? 1', text)
        self.assertIn('.accessibilityLabel(text)', text)
        self.assertNotIn('WKWebView', text)
        self.assertNotIn('URLSession', text)

    def test_actual_word_timing_remains_independent_of_visual_delay(self):
        text = (ROOT / 'Sonivo/StaggeredLyricsView.swift').read_text()
        self.assertIn('line.hasRealWordTimings ? line.words : nil', text)
        self.assertIn('let timingsMatch', text)
        self.assertIn('if let time = currentTime', text)
        self.assertIn('LyricsTimingStandard.hasStarted(time: time, start: $0)', text)
        live = text.split('if let time = currentTime', 1)[1].split('} else {', 1)[0]
        for delayed in ['reveal(', 'translateBy', 'blur(', 'clip(']:
            self.assertNotIn(delayed, live)
        self.assertIn('LyricsClockSurface(clock: frameClock, player: player, lyrics: lyrics)', text)
        self.assertIn('currentTime: isActive && line.hasRealWordTimings ? clock.frameTime : 0', text)
        self.assertIn('LyricsPlaybackClock.seekTime(', text)

    def test_long_short_and_empty_lines_have_bounded_timing(self):
        for count in [0, 1, 2, 10, 100, 1000]:
            for available in [.12, .3, 1, 4, 100]:
                duration, delay, total = timing(count, available)
                self.assertTrue(all(math.isfinite(x) for x in [duration, delay, total]))
                self.assertGreaterEqual(duration, .12)
                self.assertLessEqual(delay, .08)
                self.assertLessEqual(total, 1.8 + 1e-12)
                self.assertLessEqual(total, max(.12, available * .70) + 1e-12)

    def test_reveal_is_ordered_and_reaches_full_legibility(self):
        duration, delay, total = timing(8, 4)
        def reveal(elapsed, index):
            fraction = min(1, max(0, (elapsed - index * delay) / duration))
            return 1 - (1 - fraction) ** 3
        self.assertGreater(reveal(.15, 0), reveal(.15, 3))
        for i in range(8):
            self.assertEqual(reveal(total + .01, i), 1)
            self.assertEqual(reveal(-1, i), 0)

    def test_unicode_punctuation_and_whitespace_are_preserved(self):
        for text in ['', 'Привет,  мир!', 'one\ntwo\tthree', '  музыка 🎵✨', 'Не-е-ет…', '你好 世界', 'supercalifragilisticexpialidocious']:
            self.assertEqual(''.join(segments(text)), text)
        self.assertEqual(segments('Привет, мир!'), ['Привет, ', 'мир!'])

    def test_preview_and_manual_scroll_have_lifecycle_guards(self):
        text = (ROOT / 'Sonivo/StaggeredLyricsView.swift').read_text()
        self.assertIn('paused: reduceMotion || scenePhase != .active', text)
        self.assertIn('onDisappear { interactionResetTask?.cancel() }', text)
        self.assertIn('if !isUserInteracting { centerCurrentLine', text)
        self.assertIn('Button("К текущей")', text)
        self.assertIn('private var activeIndex: Int? { frameClock.activeIndex }', text)


if __name__ == '__main__':
    unittest.main()
