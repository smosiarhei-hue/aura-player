"""Source guards; real Swift/URLProtocol fixtures run in the existing macOS test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class YandexPersonalAuthTests(unittest.TestCase):
    def test_device_flow_has_no_embedded_webview_or_webauthn_override(self):
        view = (ROOT / 'Sonivo/YandexAuthSheet.swift').read_text()
        for forbidden in ['WKWebView', 'PublicKeyCredential', 'navigator.credentials', 'access_token=', 'response_type=token']:
            self.assertNotIn(forbidden, view)
        for expected in ['openURL(url)', 'code.user_code', 'ContinuousClock()', 'Task.checkCancellation()', '.onDisappear { cancel()', 'operation?.cancel()', 'interval += 5', 'YandexAuthError.pending']:
            self.assertIn(expected, view)
        self.assertNotIn('UIPasteboard.general.string = token', view)
        self.assertIn('Яндекса.\\n2.', view)
        self.assertNotIn('Яндекса.\n2.', view)

    def test_upstream_protocol_and_form_encoding_are_explicit(self):
        client = (ROOT / 'Sonivo/YandexDeviceAuthClient.swift').read_text()
        for expected in ['https://oauth.yandex.ru/', '"device/code"', '"grant_type": "device_code"', '"code": code', '"grant_type": "refresh_token"', 'configuration.httpCookieStorage = nil', 'configuration.urlCache = nil', '"authorization_pending"', '"slow_down"', '"access_denied"', '"expired_token"', '"invalid_grant"']:
            self.assertIn(expected, client)
        self.assertIn('YandexOAuthForm.encode(fields)', client)
        self.assertIn('url.user == nil, url.password == nil, url.port == nil', client)
        self.assertNotIn('print(', client)
        self.assertNotIn('SonivoDiagnostics.log', client)

    def test_user_token_never_falls_back_or_is_persisted_in_defaults(self):
        for path in (ROOT / 'Sonivo').glob('*.swift'):
            source = path.read_text()
            self.assertNotIn('defaultToken', source, str(path))
            self.assertNotIn('UserDefaults.standard.set(token, forKey: "ym.token")', source)
        service = (ROOT / 'Sonivo/yandexmusicservice.swift').read_text()
        self.assertIn('defaults.removeObject(forKey: "ym.token")', service)
        self.assertNotIn('defaults.string(forKey: "ym.token")', service)
        self.assertIn('savedProfile.uid == credential?.uid', service)
        self.assertIn('decoded.result?.plus?.hasPlus ?? false', service)

    def test_keychain_save_updates_without_destroying_old_session(self):
        store = (ROOT / 'Sonivo/YandexCredentialStore.swift').read_text()
        save = store.split('static func save(', 1)[1].split('static func remove()', 1)[0]
        self.assertIn('SecItemUpdate', save)
        self.assertIn('errSecItemNotFound', save)
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly', save)
        self.assertNotIn('SecItemDelete', save)
        for field in ['accessToken', 'refreshToken', 'expiresAt', 'uid']:
            self.assertIn(field, store)

    def test_candidate_validation_and_cancellation_precede_installation(self):
        service = (ROOT / 'Sonivo/yandexmusicservice.swift').read_text()
        login = service.split('func loginWithOAuthToken(', 1)[1].split('private func ensureValidCredentials', 1)[0]
        self.assertLess(login.index('await profile(for: result.access_token)'), login.index('YandexCredentialStore.save(candidate)'))
        self.assertLess(login.index('!Task.isCancelled'), login.index('YandexCredentialStore.save(candidate)'))
        self.assertLess(login.index('YandexCredentialStore.save(candidate)'), login.index('token = candidate.accessToken'))
        self.assertIn('loginAttemptID == attempt', login)
        self.assertIn('accountGeneration == generation', login)
        transport = service.split('func sessionData(', 1)[1].split('func likeTrackOnServer', 1)[0]
        self.assertLess(transport.index('let generation = accountGeneration'), transport.index('await ensureValidCredentials()'))
        self.assertIn('guard accountGeneration == generation else { throw CancellationError() }', transport)
        self.assertIn('request.setValue("OAuth " + activeToken', transport)

    def test_account_cleanup_preserves_local_tracks_and_invalidates_radio(self):
        service = (ROOT / 'Sonivo/yandexmusicservice.swift').read_text()
        library = (ROOT / 'Sonivo/librarystore.swift').read_text()
        identity = service.split('static func isPersonalYandexTrack(', 1)[1].split('func logout()', 1)[0]
        self.assertIn('track.isStream && ymId(fromFileName: track.fileName) != nil', identity)
        cleanup = library.split('func clearYandexAccountData()', 1)[1].split('func setYandexPlaylistsFromCloud', 1)[0]
        self.assertNotIn('FileManager', cleanup)
        self.assertNotIn('clearFavorites()', cleanup)
        self.assertNotIn('playlists.removeAll()', cleanup)
        logout = service.split('func logout()', 1)[1].split('private func authorizedRequest', 1)[0]
        for expected in ['accountGeneration = UUID()', 'loginAttemptID = UUID()', 'token = ""', 'YandexCredentialStore.remove()', 'resetPersonalState()', 'stopOldYandexPlayback()']:
            self.assertIn(expected, logout)
        self.assertIn('endStationSession()', service.split('private func resetPersonalState', 1)[1])
        self.assertIn('let accountGeneration = YandexMusicService.shared.accountGeneration', library)

    def test_cloud_import_does_not_commit_stale_or_failed_results(self):
        playlists = (ROOT / 'Sonivo/YandexAccountPlaylists.swift').read_text()
        self.assertIn('/users/\\(uid)/playlists/list', playlists)
        self.assertIn('currentUser?.uid == uid', playlists)
        self.assertIn('accountGeneration == generation', playlists)
        self.assertIn('items.count == entries.count', playlists)
        service = (ROOT / 'Sonivo/yandexmusicservice.swift').read_text()
        likes = service.split('private func fetchUserLikes', 1)[1].split('func fetchAccountStatus()', 1)[0]
        self.assertIn('-> [YMTrackItem]?', likes)
        self.assertIn('return nil', likes)
        self.assertIn('guard !prefixIds.isEmpty else { return [] }', likes)
        self.assertIn('guard let likedItems = await fetchUserLikes', service)


if __name__ == '__main__':
    unittest.main()
