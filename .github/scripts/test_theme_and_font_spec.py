# Path: .github/scripts/test_theme_and_font_spec.py
"""Tests for Theme, Font Manager (5 custom fonts), Localization, and ProMotion scroll physics."""

import unittest
from pathlib import Path


class ThemeAndFontSpecTests(unittest.TestCase):
    def setUp(self):
        self.repo_root = Path(__file__).resolve().parent.parent.parent
        self.theme_manager = self.repo_root / "Sonivo" / "ThemeFontManager.swift"
        self.theme_file = self.repo_root / "Sonivo" / "theme.swift"
        self.l10n_file = self.repo_root / "Sonivo" / "SonivoL10n.swift"
        self.settings_file = self.repo_root / "Sonivo" / "settingsview.swift"
        self.app_file = self.repo_root / "Sonivo" / "sonivoapp.swift"
        self.artist_file = self.repo_root / "Sonivo" / "artistviews.swift"

    def test_files_exist(self):
        self.assertTrue(self.theme_manager.exists(), "ThemeFontManager.swift missing")
        self.assertTrue(self.theme_file.exists(), "theme.swift missing")
        self.assertTrue(self.l10n_file.exists(), "SonivoL10n.swift missing")
        self.assertTrue(self.settings_file.exists(), "settingsview.swift missing")
        self.assertTrue(self.app_file.exists(), "sonivoapp.swift missing")
        self.assertTrue(self.artist_file.exists(), "artistviews.swift missing")

    def test_five_requested_fonts(self):
        content = self.theme_manager.read_text(encoding="utf-8")
        # 1. Neue Montreal
        self.assertIn("neueMontreal", content)
        self.assertIn('"Neue Montreal"', content)
        # 2. Satoshi
        self.assertIn("satoshi", content)
        self.assertIn('"Satoshi"', content)
        # 3. General Sans
        self.assertIn("generalSans", content)
        self.assertIn('"General Sans"', content)
        # 4. Instrument Sans
        self.assertIn("instrumentSans", content)
        self.assertIn('"Instrument Sans"', content)
        # 5. PP Neue Machina
        self.assertIn("ppNeueMachina", content)
        self.assertIn('"PP Neue Machina"', content)

    def test_theme_colors_palette(self):
        content = self.theme_manager.read_text(encoding="utf-8")
        self.assertIn("AppThemeColor", content)
        self.assertIn("crimson", content)
        self.assertIn("sunset", content)
        self.assertIn("violet", content)
        self.assertIn("cyan", content)
        self.assertIn("emerald", content)
        self.assertIn("cobalt", content)

    def test_theme_swift_bindings(self):
        content = self.theme_file.read_text(encoding="utf-8")
        self.assertIn("ThemeFontManager.shared.accentColor", content)
        self.assertIn("ThemeFontManager.shared.displayFont", content)
        self.assertIn("ThemeFontManager.shared.font", content)
        self.assertIn("ThemeFontManager.shared.roundedFont", content)

    def test_settings_includes_font_and_theme_pickers(self):
        content = self.settings_file.read_text(encoding="utf-8")
        self.assertIn("AppCustomFont.allCases", content)
        self.assertIn("AppThemeColor.allCases", content)
        self.assertIn("themeManager.selectedFont", content)
        self.assertIn("themeManager.selectedTheme", content)

    def test_smooth_scroll_physics(self):
        content = self.app_file.read_text(encoding="utf-8")
        self.assertIn("UIScrollView.appearance().decelerationRate = UIScrollView.DecelerationRate.normal", content)

    def test_russian_default_localization(self):
        content = self.l10n_file.read_text(encoding="utf-8")
        self.assertIn("self.language = .ru", content)
        self.assertIn("Популярные треки", content)
        self.assertIn("Свежий релиз", content)


if __name__ == "__main__":
    unittest.main()
