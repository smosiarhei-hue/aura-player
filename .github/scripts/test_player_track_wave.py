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
        text=source('yandexmusicservice.swift').split('private func requestTrackStationQueue',1)[1].split('func getStationTracks',1)[0]
        for expected in ['/rotor/station/', 'stationId.hasPrefix("track:")', '(200..<300).contains(http.statusCode)', 'try Task.checkCancellation()', 'result.append(item)', 'queueIDs.suffix(400)', 'history: [seedID]']:
            self.assertIn(expected,text)
        for forbidden in ['getChart', 'personalPicks', '.sorted', '.shuffled', 'extractVector', 'filterAndRankWave']:
            self.assertNotIn(forbidden,text)
    def test_station_and_playback_generations_reject_stale_requests(self):
        text=source('yandexmusicservice.swift').split('func startYandexTrackStation',1)[1].split('func getStationTracks',1)[0]
        for expected in ['trackStationRequestID == requestID','rotorSessionID == sessionID','PlayerCore.shared.playbackRequestID == playbackID','activeStationId == station','!Task.isCancelled']:
            self.assertIn(expected,text)
        screen=source('PlayerScreenV2.swift').split('private func startTrackWave()',1)[1].split('private func startAIVibeWave',1)[0]
        for expected in ['guard !waveLoading','trackWaveRequestID == requestID','track?.id == current.id','activateYandexTrackWave(tracks: waveTracks)','guard !waveTracks.isEmpty']:
            self.assertIn(expected,screen)
        self.assertNotIn('startTrackWave(seed:',screen)
        lifetime=source('PlayerScreenV2.swift').split('.onDisappear {\n            trackWaveTask?.cancel()',1)[1].split('teardownVideoLooper()',1)[0]
        self.assertIn('waveLoading = false',lifetime)
    def test_all_player_refills_prefer_track_station_before_local_engine(self):
        core=source('playercore.swift')
        self.assertEqual(core.count('await YandexMusicService.shared.refillYandexTrackWave(target: 20)'),2)
        refill=core.split('func refillQueueIfNeeded()',1)[1].split('private func flushListeningStats()',1)[0]
        self.assertLess(refill.index('await ym.refillYandexTrackWave'),refill.index('await MoodRadioEngine.shared.refillTrackWaveQueue'))
        self.assertIn('serverOrdered ? rawTracks : UserTasteEngine.shared.filterAndRankWave',refill)
        self.assertIn('guard !refillingTrackStation || ym.rotorSessionID == sessionID',refill)
    def test_native_secondary_actions_are_below_primary_wave_and_scrollable(self):
        screen=source('PlayerScreenV2.swift')
        body=screen.split('var body: some View',1)[1].split('.sheet(item:',1)[0]
        self.assertIn('ScrollView(.vertical)',body)
        self.assertIn('.simultaneousGesture(playerDismissGesture(requiresScrollTop: false))',body)
        self.assertNotIn('.background(SN.bg.ignoresSafeArea())\n        .simultaneousGesture',body)
        deck=screen.split('private func lowerDeck',1)[1].split('private var trackWaveButton',1)[0]
        for first,second in [('metadataRow','transportControls'),('FluidVolumeSlider()','trackWaveButton'),('trackWaveButton','secondaryPlayerActions')]:
            self.assertLess(deck.index(first),deck.index(second))
        actions=screen.split('private var secondaryPlayerActions',1)[1].split('private var sleepTimerBottomButton',1)[0]
        for expected in ['AirPlayButtonView','sleepTimerBottomButton','"Эквалайзер"','"Очередь"','"Текст песни"']: self.assertIn(expected,actions)
    def test_dismissal_is_on_header_and_artwork_not_audio_controls(self):
        text=source('PlayerScreenV2.swift')
        body=text.split('var body: some View',1)[1].split('.sheet(item:',1)[0]
        self.assertIn('.contentShape(Rectangle())',body)
        self.assertIn('.simultaneousGesture(playerDismissGesture(requiresScrollTop: true))',body)
        self.assertIn('.onScrollGeometryChange(for: Bool.self)',body)
        self.assertIn('geometry.contentOffset.y + geometry.contentInsets.top <= 1',body)
        deck=text.split('private func lowerDeck',1)[1].split('private var trackWaveButton',1)[0]
        self.assertNotIn('playerDismissGesture',deck)
        sliders=text.split('struct FluidVolumeSlider:',1)[1].split('struct VideoShotPlayerView:',1)[0]
        self.assertNotIn('playerDismissGesture',sliders)
    def test_swipe_direction_is_latched_and_lyrics_header_can_dismiss(self):
        text=source('PlayerScreenV2.swift')
        drag=text.split('private func playerDismissGesture',1)[1].split('private var isFullScreenVideoShot',1)[0]
        self.assertIn('if dismissDragEligible == nil',drag)
        self.assertIn('PlayerDismissPolicy.canBegin(',drag)
        self.assertIn('PlayerDismissPolicy.shouldClose(',drag)
        self.assertIn('dismissDragEligible = nil',drag)
        self.assertIn('.updating($dismissGestureActive)',drag)
        self.assertIn('.onChange(of: dismissGestureActive)',text)
        self.assertNotIn('!showLyricsMode',drag)
        lyrics=text.split('private func lyricsPlayerLayout',1)[1].split('private var lyricsTopHeader',1)[0]
        self.assertIn('.simultaneousGesture(playerDismissGesture(requiresScrollTop: false))',lyrics)
    def test_button_is_accessible_and_loading_or_local_track_is_disabled(self):
        button=source('PlayerScreenV2.swift').split('private var trackWaveButton',1)[1].split('private var secondaryPlayerActions',1)[0]
        for expected in ['Button(action: startTrackWave)','minHeight: 56','.disabled(!catalogTrack || waveLoading)','ProgressView()','.accessibilityValue(','.accessibilityHint(','.fixedSize(horizontal: false, vertical: true)']: self.assertIn(expected,button)
    def test_button_is_native_glass_and_has_no_provider_brand(self):
        button=source('PlayerScreenV2.swift').split('private var trackWaveButton',1)[1].split('private var secondaryPlayerActions',1)[0]
        self.assertIn('"Моя волна по текущему треку"',button)
        self.assertNotIn('Яндекс',button)
        self.assertIn('.glassEffect(.regular.tint(glassTint).interactive(), in: .rect(cornerRadius: SN.radius))',button)
        self.assertIn('.buttonStyle(.plain)',button)
        self.assertNotIn('.strokeBorder',button)
        self.assertNotIn('.ultraThinMaterial',button)
        self.assertIn('minHeight: 56',button)
    def test_button_tint_uses_only_current_artwork_not_mood_or_random_palette(self):
        text=source('PlayerScreenV2.swift')
        button=text.split('private var trackWaveButton',1)[1].split('private var secondaryPlayerActions',1)[0]
        self.assertIn('resolvedArtworkPaletteTrackID == track?.id ? artworkPaletteColors : []',button)
        self.assertIn('coverColors.first?.opacity(0.12) ?? Color.clear',button)
        self.assertNotIn('PlayerTrackWaveBackdrop',text)
        self.assertNotIn('Image(systemName: "waveform")',button)
        update=text.split('private func updatePalette',1)[1].split('private func refreshPalette',1)[0]
        self.assertIn('!Task.isCancelled, track?.id == trackID, paletteTrackId == trackID',update)
        self.assertIn('resolvedArtworkPaletteTrackID = trackID',update)
    def test_player_background_is_uniform_cover_tint_and_home_is_untouched(self):
        text=source('PlayerScreenV2.swift')
        block=text.split('private var background:',1)[1].split('private var topHeader:',1)[0]
        self.assertIn('resolvedArtworkPaletteTrackID == track?.id',block)
        self.assertIn('base.overlay((coverColor ?? Color.clear).opacity(0.22))',block)
        for forbidden in ['LinearGradient','RadialGradient','PlayerMusicReactiveBackdrop','VideoShotPlayerView','TimelineView','Image(uiImage:']:
            self.assertNotIn(forbidden,block)
        button=text.split('private var trackWaveButton',1)[1].split('private var secondaryPlayerActions',1)[0]
        for forbidden in ['Canvas','TimelineView','PlayerTrackWaveBackdrop','waveform','Image(uiImage:']:
            self.assertNotIn(forbidden,button)
    def test_server_wave_does_not_enter_local_vibe_refill(self):
        text=source('MoodRadioEngine.swift').split('func activateYandexTrackWave',1)[1].split('func startTrackWave',1)[0]
        self.assertIn('moodRequestID = UUID()',text)
        self.assertIn('isTrackWaveActive = false',text)
        self.assertIn('activeMood = nil',text)
        self.assertIn('replaceUpcomingQueue(with: tracks)',text)
        self.assertNotIn('extractVector',text)
if __name__=='__main__': unittest.main()
