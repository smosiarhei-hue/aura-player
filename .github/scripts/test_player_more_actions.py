"""Regression contracts for the player's scrollable actions sheet."""
from pathlib import Path
import unittest


SCREEN = Path(__file__).resolve().parents[2] / 'Sonivo' / 'PlayerScreenV2.swift'


class PlayerMoreActionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCREEN.read_text(encoding='utf-8')
        cls.button = cls.source.split('private var moreMenuButton:', 1)[1].split('private var moreActionsSheet:', 1)[0]
        cls.sheet = cls.source.split('private var moreActionsSheet:', 1)[1].split('private var artistSelectionSheet:', 1)[0]

    def test_ellipsis_uses_a_persistent_scrollable_sheet_in_both_player_modes(self):
        self.assertEqual(self.source.count('            moreMenuButton'), 2)
        self.assertIn('Button { openModal(.more) }', self.button)
        self.assertNotIn('Menu {', self.button)
        self.assertNotIn('isPlaying', self.button)
        self.assertIn('case .more:\n                moreActionsSheet', self.source)
        self.assertIn('NavigationStack {', self.sheet)
        self.assertIn('List {', self.sheet)
        self.assertIn('.presentationDetents([.large])', self.sheet)
        self.assertIn('.presentationContentInteraction(.scrolls)', self.sheet)
        self.assertNotIn('.id(', self.sheet)
        self.assertNotIn('isPlaying', self.sheet)

    def test_navigation_dismisses_sheet_before_presenting_next_screen(self):
        dismiss = self.source.split('private func scheduleAfterMenuDismiss', 1)[1].split('private func togglePlayback', 1)[0]
        self.assertLess(dismiss.index('dismissMoreActions()'), dismiss.index('Task {'))
        self.assertIn('guard !Task.isCancelled, isPresented', dismiss)
        for action in ['queue', 'equalizer', 'sleepTimer', 'settings']:
            self.assertIn(f'openModal(.{action}, deferForMenu: true)', self.sheet)
        self.assertIn('scheduleAfterMenuDismiss {', self.sheet)
        self.assertIn('Button("Закрыть") { dismissMoreActions() }', self.sheet)

    def test_action_and_toggle_availability_are_preserved(self):
        for text in ['Не рекомендовать этот трек', 'Моя волна по текущему треку',
                     'AI Вайб-волна', 'Видеошоты', 'Neural Engine:', 'Текст песни',
                     'Очередь', 'Эквалайзер', 'Таймер сна', 'Настройки',
                     'Скопировать лог AutoMix', 'Остановить и очистить']:
            self.assertIn(text, self.sheet)
        self.assertIn('Toggle("Видеошоты", isOn: $isVideoShotEnabled)', self.sheet)
        self.assertIn('.disabled(!waveAvailability.catalog || waveLoading)', self.sheet)
        self.assertIn('.disabled(track == nil || waveLoading || AIDJService.shared.isVibeWaveGenerating)', self.sheet)


if __name__ == '__main__':
    unittest.main()
