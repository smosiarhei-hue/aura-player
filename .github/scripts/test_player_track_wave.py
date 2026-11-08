"""Player hierarchy and strict Yandex track-radio source regression guards."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
def source(name): return (ROOT / 'Sonivo' / name).read_text()
class PlayerTrackWaveTests(unittest.TestCase):
    def test_track_wave_has_no_local_or_ai_candidate_sources(self):
        text=source('trackwave.swift').split('func buildTrackWave',1)[1].split('func buildArtistWave',1)[0]
        self.assertIn('Self.ymId(fromFileName: seed.fileName)',text)
        self.assertIn('startYandexTrackStation(seedID: seedID',text)
        for forbidden in ['extractVector', 'shuffled()', 'AIRankerService', 'personalPicks', 'getChart', 'getArtist', 'filterAndRankWave']:
            self.assertNotIn(forbidden,text)
    def test_rotor_only_queue_preserves_server_sequence_and_checks_http(self):
        text=source('YandexWaveSession.swift')
        for expected in ['/rotor/session/new', '/tracks', '(200..<300).contains(response.statusCode)', 'try Task.checkCancellation()', 'accepted.append(item)', '"queue": Array(queue.suffix(1000))']:
            self.assertIn(expected,text)
        for forbidden in ['getChart', 'personalPicks', '.sorted', '.shuffled', 'extractVector', 'filterAndRankWave']:
            self.assertNotIn(forbidden,text)
    def test_station_and_playback_generations_reject_stale_requests(self):
        text=source('yandexmusicservice.swift').split('func startYandexWave',1)[1].split('func getStationTracks',1)[0]
        for expected in ['trackStationRequestID == requestID','rotorSessionID == session','PlayerCore.shared.playbackRequestID == playback','!Task.isCancelled']:
            self.assertIn(expected,text)
        screen=source('PlayerScreenV2.swift').split('private func startTrackWave()',1)[1].split('private func startAIVibeWave',1)[0]
        for expected in ['guard !waveLoading','trackWaveRequestID == requestID','track?.id == current.id','activateYandexTrackWave(tracks: waveTracks)','guard !waveTracks.isEmpty']:
            self.assertIn(expected,screen)
        self.assertNotIn('startTrackWave(seed:',screen)
        lifetime=source('PlayerScreenV2.swift').split('.onDisappear {\n            trackWaveTask?.cancel()',1)[1].split('teardownVideoLooper()',1)[0]
        self.assertIn('waveLoading = false',lifetime)
    def test_all_player_refills_prefer_track_station_before_local_engine(self):
        core=source('playercore.swift')
        loader=core.split('private func loadQueueContinuation',1)[1].split('func refillQueueIfNeeded',1)[0]
        self.assertLess(loader.index('await ym.refillYandexTrackWave'),loader.index('await MoodRadioEngine.shared.refillTrackWaveQueue'))
        self.assertIn('continuationLoader.load(key:key)',loader)
        refill=core.split('func refillQueueIfNeeded()',1)[1].split('private func flushListeningStats()',1)[0]
        self.assertIn('self.queueContinuationID == queueID',refill)
        self.assertIn('ym.accountGeneration == account',refill)
        self.assertNotIn('filterAndRankWave',refill)
        self.assertIn('remainingAhead <= (isYandexWavePlayback ? 5 : 0)',refill)
    def test_native_utility_row_hosts_sleep_eq_and_wave_lives_in_menu(self):
        screen=source('PlayerScreenV2.swift')
        body=screen.split('var body: some View',1)[1].split('.sheet(item:',1)[0]
        self.assertIn('ScrollView(.vertical)',body)
        self.assertIn('coverTopClearance',body)
        self.assertIn('coverBloomTones',screen)
        self.assertNotIn('playerTopColorBloom',screen)
        self.assertNotIn('playerDismissGesture',body)
        self.assertNotIn('.background(SN.bg.ignoresSafeArea())\n        .simultaneousGesture',body)
        deck=screen.split('private func lowerDeck',1)[1].split('private var coverBloomTones',1)[0]
        for first,second in [
            ('metadataRow','transportControls'),
            ('FluidVolumeSlider()','primaryUtilityRow'),
        ]:
            self.assertLess(deck.index(first),deck.index(second))
        self.assertNotIn('trackWaveButton',deck)
        self.assertNotIn('secondaryPlayerActions',deck)
        self.assertNotIn('Действия ниже',deck)
        utility=screen.split('private var primaryUtilityRow',1)[1].split('private var sleepTimerUtilityButton',1)[0]
        for expected in ['AirPlayButtonView','quote.bubble','list.bullet','"Очередь"','sleepTimerUtilityButton','SonivoEqualizerGlyph()','"Эквалайзер"']:
            self.assertIn(expected,utility)
        menu=screen.split('private var moreMenuButton',1)[1].split('private var artistSelectionSheet',1)[0]
        self.assertIn('startTrackWave()',menu)
        self.assertIn('"Моя волна по текущему треку"',menu)
        self.assertIn('trackWaveMenuAvailability',menu)
        self.assertNotIn('private var trackWaveButton',screen)
        self.assertNotIn('private var secondaryPlayerActions',screen)
    def test_dismissal_is_explicit_fullscreen_at_every_player_entry_point(self):
        presentation=source('PlayerSheetPresentation.swift')
        self.assertIn('struct PlayerFullscreenPresentation',presentation)
        self.assertIn('content.interactiveDismissDisabled(true)',presentation)
        self.assertNotIn('.navigationTransition(.zoom',presentation)
        for token in ['presentationDetents', 'presentationCornerRadius']:
            self.assertNotIn(token,presentation)
        for name in ['sonivoapp.swift','SonivoHomeRedesignedView.swift','homeview.swift']:
            entry=source(name)
            self.assertIn('.fullScreenCover(isPresented: $showPlayer)',entry)
            self.assertIn('.modifier(PlayerFullscreenPresentation(',entry)
            self.assertIn('.matchedTransitionSource(',entry)
            self.assertNotIn('.sheet(isPresented: $showPlayer)',entry)
    def test_fullscreen_background_keeps_controls_below_system_safe_insets(self):
        screen=source('PlayerScreenV2.swift')
        self.assertIn('GeometryReader { safeGeometry in',screen)
        self.assertIn('safeGeometry.safeAreaInsets.top',screen)
        self.assertIn('safeGeometry.safeAreaInsets.bottom',screen)
        self.assertIn('let topInset = max(safeTop, 12)',screen)
        self.assertIn('.ignoresSafeArea(.container, edges: .all)',screen)
        self.assertIn('lowerDeck(safeAreaBottom: safeBottom, coverWidth: totalWidth)',screen)
    def test_system_drag_does_not_install_competing_manual_gestures_or_stop_music(self):
        text=source('PlayerScreenV2.swift')
        for token in ['dismissOffsetY','dismissDragEligible','playerDismissGesture','dismissGestureActive']:
            self.assertNotIn(token,text)
        self.assertIn('private func close() { Haptics.tap(.light); isPresented = false }',text)
        sliders=text.split('struct FluidVolumeSlider:',1)[1].split('struct VideoShotPlayerView:',1)[0]
        self.assertNotIn('DragGesture(minimumDistance: 15)',sliders)
    def test_wave_menu_item_is_accessible_and_loading_or_local_track_is_disabled(self):
        menu=source('PlayerScreenV2.swift').split('private var moreMenuButton',1)[1].split('private var artistSelectionSheet',1)[0]
        for expected in ['startTrackWave()','trackWaveMenuAvailability','.disabled(!waveAvailability.catalog || waveLoading)','"Моя волна по текущему треку"']:
            self.assertIn(expected,menu)
    def test_wave_menu_has_no_provider_brand(self):
        menu=source('PlayerScreenV2.swift').split('private var moreMenuButton',1)[1].split('private var artistSelectionSheet',1)[0]
        self.assertIn('"Моя волна по текущему треку"',menu)
        self.assertNotIn('Яндекс',menu)
    def test_player_background_is_uniform_cover_tint_and_home_is_untouched(self):
        text=source('PlayerScreenV2.swift')
        block=text.split('private var background:',1)[1].split('private var topHeader:',1)[0]
        self.assertIn('resolvedArtworkPaletteTrackID == track?.id',block)
        self.assertIn('Color.black.overlay((coverColor ?? Color.clear).opacity(0.28))',block)
        self.assertIn('? dominantArtworkColor : nil',block)
        normal_player = block.split('return AnyView(',1)[1]
        for forbidden in ['LinearGradient','RadialGradient','PlayerMusicReactiveBackdrop','VideoShotPlayerView','TimelineView','Image(uiImage:']:
            self.assertNotIn(forbidden,normal_player)
        self.assertIn('coverBloomTones',text)
        self.assertNotIn('playerTopColorBloom',text)
        self.assertNotIn('playerTopNativeBlur',text)
    def test_server_wave_does_not_enter_local_vibe_refill(self):
        text=source('MoodRadioEngine.swift').split('func activateYandexTrackWave',1)[1].split('func startTrackWave',1)[0]
        self.assertIn('moodRequestID = UUID()',text)
        self.assertIn('isTrackWaveActive = false',text)
        self.assertIn('activeMood = nil',text)
        self.assertIn('replaceUpcomingQueue(with: tracks)',text)
        self.assertNotIn('extractVector',text)
if __name__=='__main__': unittest.main()
