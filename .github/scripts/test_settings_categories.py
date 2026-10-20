from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SettingsCategoriesTests(unittest.TestCase):
    def setUp(self):
        self.settings = (ROOT/'Sonivo/settingsview.swift').read_text()
        self.ui = (ROOT/'Sonivo/SettingsUI.swift').read_text()
    def test_overview_contains_only_seven_category_links(self):
        overview=self.settings.split('private var overview: some View {',1)[1].split('private func categoryLink',1)[0]
        for name in ['music','playback','lyrics','appearance','haptics','storage','about']:
            self.assertEqual(overview.count(f'categoryLink(.{name})'),1)
        for text in ['Toggle(', 'Slider(', 'SecureField(', '.lyricsSources']:
            self.assertNotIn(text,overview)
        self.assertIn('if category == nil {\n            NavigationStack',self.settings)
        self.assertEqual(self.settings.count('NavigationStack {'),1)
    def test_existing_controls_keep_their_bindings(self):
        for binding in ['catalogSourceRaw','videoShotsEnabled','musixmatchProxyInput','musixmatchKeyInput','l10n.language','settings.lyricsDesign','settings.isNeuralEngineEnabled','settings.lyricsFontSize','settings.hapticsEnabled','settings.scrubHapticsEnabled','settings.musicHapticsEnabled','settings.musicHapticsIntensity','player.eqHeadphonesOnly','player.spatialAudioEnabled','player.crossfadeDuration']:
            self.assertIn('$'+binding,self.settings)
        for action in ['await ym.syncAccountData()', 'ym.logout()', 'socialAuth.signOut()', 'await library.rescan()', 'library.resetIndex()', 'await mediaCache.clearGeneratedCache()', 'player.selectQuality(quality)', 'player.transitionMode = mode', 'MusicHapticsManager.shared.playPreview', 'musixmatch.saveProxyURL', 'musixmatch.removeProxyURL', 'musixmatch.saveAPIKey', 'musixmatch.removeAPIKey']:
            self.assertIn(action,self.settings)
    def test_provider_credentials_are_on_advanced_page(self):
        general=self.settings.split('private var lyricsSettings: some View {',1)[1].split('private var lyricsSourceSettings',1)[0]
        self.assertIn('SettingsView(category: .lyricsSources)',general)
        self.assertNotIn('SecureField(',general)
        advanced=self.settings.split('private var lyricsSourceSettings: some View {',1)[1].split('private var hapticsSettings',1)[0]
        self.assertIn('SecureField(',advanced)
        self.assertIn('invalidateCache()',advanced)
        self.assertIn('.didUpdateCustomLyrics',advanced)
    def test_destructive_data_actions_require_confirmation(self):
        self.assertIn('showResetIndexConfirmation = true',self.settings)
        self.assertIn('showClearCacheConfirmation = true',self.settings)
        self.assertIn('.confirmationDialog("Сбросить индекс?"',self.settings)
        self.assertIn('.confirmationDialog("Очистить кэш?"',self.settings)
        self.assertIn('локальные плейлисты будут сброшены',self.settings)
        self.assertEqual(self.settings.count('library.resetIndex()'),1)
        self.assertEqual(self.settings.count('await mediaCache.clearGeneratedCache()'),1)
    def test_shared_native_ui_tokens_and_accessibility(self):
        for token in ['SN.text', 'SN.accent', 'SN.inkMuted', 'SN.tapTarget', 'SN.radiusSmall', '.fixedSize(horizontal: false, vertical: true)', '.accessibilityHidden(true)']:
            self.assertIn(token,self.ui)
        for file in ['settingsview.swift','SonivoAppearanceView.swift','AppIconPickerView.swift']:
            self.assertIn('.modifier(SonivoSettingsFormStyle())',(ROOT/'Sonivo'/file).read_text())
    def test_copy_avoids_unverified_quality_and_refresh_claims(self):
        self.assertNotIn('ProMotion (до 120 Гц)',self.settings)
        self.assertNotIn('без искажений',self.settings)
        self.assertIn('Выбранное качество — предпочтение',self.settings)
        self.assertIn('Стерео не становится Dolby Atmos',self.settings)
        self.assertIn('без токенов и данных Яндекса',self.settings)

if __name__=='__main__': unittest.main()
