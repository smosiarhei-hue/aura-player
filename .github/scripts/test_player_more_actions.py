"""Regression contracts for the player's compact, stable native actions menu."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class PlayerMoreActionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.screen = (ROOT / 'Sonivo' / 'PlayerScreenV2.swift').read_text(encoding='utf-8')
        cls.native = (ROOT / 'Sonivo' / 'PlayerMoreMenu.swift').read_text(encoding='utf-8')
        cls.button = cls.screen.split('private var moreMenuButton:', 1)[1].split('private var artistSelectionSheet:', 1)[0]

    def test_compact_native_menu_in_both_player_modes(self):
        self.assertEqual(self.screen.count('            moreMenuButton'), 2)
        self.assertIn('PlayerMoreMenu(', self.button)
        self.assertNotIn('openModal(.more)', self.screen)
        self.assertNotIn('moreActionsSheet', self.screen)
        self.assertIn('button.showsMenuAsPrimaryAction = true', self.native)
        self.assertIn('UIDeferredMenuElement.uncached', self.native)
        self.assertIn('completion(coordinator.menuItems())', self.native)
        self.assertIn('button.menu = UIMenu(title: "", children: [deferred])', self.native)
        update = self.native.split('func updateUIView(', 1)[1].split('final class Coordinator', 1)[0]
        self.assertNotIn('button.menu =', update)
        self.assertIn('context.coordinator.snapshot = snapshot', update)
        self.assertIn('context.coordinator.perform = perform', update)

    def test_navigation_waits_for_native_menu_dismissal(self):
        deferral = self.screen.split('private func scheduleAfterMenuDismiss', 1)[1].split('private func togglePlayback', 1)[0]
        self.assertIn('milliseconds(320)', deferral)
        self.assertIn('guard !Task.isCancelled, isPresented', deferral)
        for action in ['queue', 'equalizer', 'sleepTimer', 'settings']:
            self.assertIn(f'openModal(.{action}, deferForMenu: true)', self.button)
        self.assertIn('scheduleAfterMenuDismiss {', self.button)

    def test_actions_availability_and_track_safety(self):
        for text in ['Не рекомендовать этот трек', 'Моя волна по текущему треку',
                     'AI Вайб-волна', 'Видеошоты', 'Neural Engine:', 'Текст песни',
                     'Очередь', 'Эквалайзер', 'Таймер сна', 'Настройки',
                     'Скопировать лог AutoMix', 'Остановить и очистить']:
            self.assertIn(text, self.native)
        self.assertIn('disabled: !s.waveAvailable || s.waveLoading', self.native)
        self.assertIn('checked: s.videoEnabled', self.native)
        self.assertIn('self.snapshot.trackID != trackID', self.native)
        self.assertIn('guard let current = track, current.id == trackID', self.button)
        self.assertNotIn('isPlaying', self.button)

if __name__ == '__main__': unittest.main()
