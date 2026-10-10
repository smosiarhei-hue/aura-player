from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
def source(name): return (ROOT / 'Sonivo' / name).read_text()

class LocalFirstAndVideoAutoplayTests(unittest.TestCase):
    def test_guest_root_does_not_mount_catalog_or_radio_and_sheet_survives_login(self):
        root = source('sonivoapp.swift')
        self.assertIn('if ym.isUserLoggedIn { SonivoHomeRedesignedView() }', root)
        self.assertIn('else { SonivoLocalHomeView(', root)
        self.assertIn('if ym.isUserLoggedIn { SearchCatalogView() } else { SonivoLocalSearchView() }', root)
        tabs = root.split('TabView(selection: $tab)', 1)[1].split('.accessibilityIdentifier', 1)[0]
        self.assertIn('if ym.isUserLoggedIn {\n                Tab(AppTab.browse.label', tabs)
        self.assertIn('.sheet(item: $rootSheet)', root)
        self.assertIn('player.queue.removeAll { $0.isStream }', root)
        self.assertNotIn('UserDefaults', tabs)

    def test_local_home_and_search_do_not_call_network_or_create_sample_music(self):
        for name in ['SonivoLocalHomeView.swift', 'SonivoLocalSearchView.swift']:
            text = source(name)
            for forbidden in ['URLSession', 'getChart(', 'searchAll(', 'buildWaveQueue(', 'AIVideoShotGeneratorService', 'Track(fileName:']:
                self.assertNotIn(forbidden, text)
            self.assertIn('!$0.isStream', text)
        home = source('SonivoLocalHomeView.swift')
        self.assertIn('LocalAudioDocumentPicker', home)
        self.assertIn('library.importFromPicker(urls: urls)', home)
        self.assertIn('onCancel: { showPicker = false }', home)
        self.assertIn('library.isImportingFiles', home)
        self.assertIn('library.lastError', home)

    def test_guest_playback_and_playlists_exclude_remote_audio(self):
        core = source('playercore.swift')
        self.assertIn('guard !track.isStream || YandexMusicService.shared.isUserLoggedIn else { return }', core)
        self.assertIn('if !YandexMusicService.shared.isUserLoggedIn { queue.removeAll { $0.isStream } }', core)
        library = source('librarystore.swift').split('func tracks(for playlist:', 1)[1].split('// MARK: - Favorites', 1)[0]
        self.assertIn('if !YandexMusicService.shared.isUserLoggedIn', library)
        self.assertIn('!$0.isStream && FileManager.default.fileExists', library)
        self.assertIn('var list = visibleTracks', source('libraryview.swift'))

    def test_auth_ui_keeps_protocol_and_readable_code_without_fake_success(self):
        sheet = source('YandexAuthSheet.swift')
        self.assertIn('SonivoAuthWordmark(', sheet)
        self.assertIn('glassCard(corner: 24', sheet)
        self.assertIn('TimelineView(.periodic(from: .now, by: 1))', sheet)
        self.assertIn('ContinuousClock().now.duration(to:', sheet)
        connect = sheet.split('private func connect(', 1)[1]
        self.assertLess(connect.index('loginWithOAuthToken(token)'), connect.index('isConnected = true'))
        self.assertIn('if !reduceMotion { Haptics.success() }', connect)
        self.assertIn('operationID == id', connect)
        self.assertIn('isEnabled: enabled', source('SonivoAuthWordmark.swift'))
        for forbidden in ['.blur(', '.rotationEffect(', '.scaleEffect(']:
            code = sheet.split('Text(code.user_code)', 1)[1].split('TimelineView', 1)[0]
            self.assertNotIn(forbidden, code)
        self.assertIn('Подключение использует неофициальный API', sheet)

    def test_video_is_automatic_and_user_setting_is_live_and_persistent(self):
        player = source('PlayerScreenV2.swift')
        settings = source('settingsview.swift')
        self.assertIn('@AppStorage("sonivo_videoshot_enabled") private var isVideoShotEnabled = true', player)
        self.assertIn('@AppStorage("sonivo_videoshot_enabled") private var videoShotsEnabled = true', settings)
        self.assertIn('Toggle("Видеошоты", isOn: $videoShotsEnabled)', settings)
        self.assertIn('Toggle("Видеошоты", isOn: $isVideoShotEnabled)', player)
        generation = player.split('private func generateAIVideoShot', 1)[1].split('private func deleteCurrentVideoShot', 1)[0]
        self.assertNotIn('isVideoShotEnabled = true', generation)
        self.assertNotIn('UserDefaults.standard.set(true', generation)

    def test_video_is_actually_rendered_without_replacing_uniform_cover_fallback(self):
        player = source('PlayerScreenV2.swift')
        self.assertIn('VideoShotPlayerView(player: videoLooperPlayer, videoGravity: .resizeAspectFill)', player)
        self.assertIn('if isFullScreenVideoShot, let videoLooperPlayer', player)
        self.assertIn('isVideoShotEnabled && videoPlayback.isReady', player)
        setup = player.split('private func setupVideoLooper', 1)[1].split('private func teardownVideoLooper', 1)[0]
        controller = source('VideoShotPlaybackController.swift')
        self.assertIn('videoPlayer.isMuted = true', controller)
        self.assertIn('videoPlayer.volume = 0', controller)
        self.assertIn('let videoPlayer = AVQueuePlayer()', controller)
        self.assertIn('videoPlayback.configure(url: url)', setup)
        self.assertNotIn('videoPlayer.play()', setup)
        self.assertIn('updateVideoPlayback()', setup)

    def test_video_load_is_keyed_cancelled_and_never_generates_or_probes_private_lan(self):
        player = source('PlayerScreenV2.swift')
        self.assertIn('.task(id: videoLoadKey) { await loadVideoShot() }', player)
        self.assertIn('playbackTrackID: player.currentTrack?.id', player)
        self.assertIn('accountGeneration: YandexMusicService.shared.accountGeneration', player)
        load = player.split('private func loadVideoShot()', 1)[1].split('private func setupVideoLooper', 1)[0]
        self.assertIn('guard !Task.isCancelled, isVideoShotEnabled, !reduceMotion', load)
        self.assertIn('self.track?.id == requestedTrackID', load)
        for forbidden in ['192.168.', 'generateVideoShot(', 'saveVideoLocally', 'httpMethod = "HEAD"']:
            self.assertNotIn(forbidden, load)
        self.assertIn('track.isStream && YandexMusicService.shared.isUserLoggedIn', load)

    def test_video_lifecycle_handles_readiness_pause_background_and_hidden_lyrics(self):
        player = source('PlayerScreenV2.swift')
        controller = source('VideoShotPlaybackController.swift')
        self.assertIn('self.generation == request', controller)
        self.assertIn('self.isReady = status == .readyToPlay', controller)
        self.assertIn('if status == .failed { self.teardown() }', controller)
        self.assertIn('statusObservation?.cancel()', controller)
        self.assertIn('failureObservation?.cancel()', controller)
        self.assertNotIn('videoStatusPublisher', player)
        for event in ['player.isPlaying', 'scenePhase', 'isPresented']:
            self.assertIn(f'.onChange(of: {event}) {{ _, _ in updateVideoPlayback() }}', player)
        policy = source('VideoShotPlaybackPolicy.swift')
        for term in ['musicPlaying', 'sceneActive', 'playerVisible', '!lyricsVisible', '!reduceMotion']:
            self.assertIn(term, policy)
        self.assertIn('if !enabled { teardownVideoLooper() }', player)
        self.assertIn('videoShotCache = [:]', source('yandexmusicservice.swift'))

if __name__ == '__main__': unittest.main()
