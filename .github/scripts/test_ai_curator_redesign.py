"""New editorial UI and honest/cancellable/account-scoped curator contracts."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
def source(name): return (ROOT / 'Sonivo/Dify' / name).read_text()

class CuratorTests(unittest.TestCase):
    def test_no_unrelated_playlist_padding(self):
        s = source('AIPlaylistGeneratorService.swift')
        self.assertNotIn('getChart', s)
        self.assertNotIn('LibraryStore.shared.tracks {', s)
        self.assertIn('AICuratorPolicy.matches', s)
        self.assertIn('candidate.available != false', s)
        self.assertIn('accountGeneration == account', s)
    def test_no_automatic_notification_permission(self):
        s = source('AIPlaylistGeneratorService.swift')
        self.assertNotIn('requestAuthorization', s)
    def test_one_save_by_id_not_title(self):
        s = source('AIPlaylistGeneratorService.swift').split('func saveToLibrary(', 1)[1].split('func playNow', 1)[0]
        self.assertIn('initialTracks: tracks', s)
        self.assertNotIn('addTracksToPlaylist', s)
        self.assertIn('savedPlaylistID', source('AIMusicCuratorStore.swift'))
        self.assertNotIn('savedPlaylistTitles', source('AIMusicCuratorStore.swift'))
    def test_tasks_cancel_and_lookup_after_await(self):
        s = source('AIMusicCuratorStore.swift')
        self.assertIn('operation?.cancel()', s)
        self.assertIn('requestID == token', s)
        self.assertIn('messages.firstIndex(where:', s)
        self.assertIn('account == YandexMusicService.shared.accountGeneration', s)
        self.assertNotIn('messages[assistantIndex]', s)
        self.assertIn('cancel(); messages = []', s)
    def test_chat_scope_and_bounds(self):
        s = source('AIMusicCuratorStore.swift')
        self.assertIn('currentUser.map', s)
        self.assertIn('messages.v2.', s)
        self.assertIn('suffix(12)', s)
        self.assertIn('prefix(1600)', s)
        self.assertIn('AICuratorPolicy.messageLimit', s)
    def test_credentials_not_shared_or_plaintext(self):
        s = source('DifyService.swift')
        self.assertNotIn('defaultNvidiaAPIKey', s)
        self.assertNotIn('defaultDifyAPIKey', s)
        self.assertNotIn('nvapi-', s)
        self.assertIn('AICredentialStore.migrate', s)
        c = source('AICredentialStore.swift')
        self.assertIn('SecItemUpdate', c)
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly', c)
        self.assertIn('retired.contains(fingerprint)', c)
    def test_channels_and_no_reasoning_or_model_fallback(self):
        s = source('DifyService.swift')
        self.assertIn('channel == .curator ? conversations[contextKey] : nil', s)
        self.assertIn('channel: .playlistExtension', s)
        self.assertIn('channel: .video', s)
        self.assertIn('channel: .dj', source('AIDJService.swift'))
        self.assertNotIn('delta?.reasoningContent', s)
        self.assertNotIn('fallbackModels', s)
    def test_https_and_stream_errors(self):
        self.assertIn('c.scheme == "https"', source('AICuratorPolicy.swift'))
        self.assertIn('json["event"] as? String', source('DifyService.swift'))
        self.assertIn('64_000', source('DifyService.swift'))
    def test_metadata_opt_in(self):
        s = source('AIMusicAssistantView.swift')
        self.assertIn('private var shareCurrentTrack = false', s)
        self.assertIn('Передать AI название и исполнителя', s)
        self.assertIn('guard enabled', source('AICuratorPolicy.swift'))
    def test_native_motion_and_truthful_result(self):
        s = source('AIMusicAssistantView.swift')
        for token in ['glassEffect', 'accessibilityReduceMotion', 'scenePhase != .active', '1.0 / 24.0',
                      'safeAreaInset', 'Найдено', 'предложено', 'store.cancel()', 'minHeight: 44']:
            self.assertIn(token, s)
        self.assertNotIn('WKWebView', s)
    def test_guest_does_not_search_catalog(self):
        self.assertIn('guard service.isUserLoggedIn', source('AIPlaylistGeneratorService.swift'))
        self.assertIn('После входа повтори запрос', source('AIMusicAssistantView.swift'))
    def test_notice_does_not_clear_clipboard(self):
        s = source('AIMusicCuratorStore.swift')
        toast = s.split('func showToast', 1)[1].split('func copyToClipboard', 1)[0]
        self.assertNotIn('UIPasteboard', toast)
