from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
def source(name):return (ROOT/'Sonivo'/name).read_text()
class YandexWaveSessionTests(unittest.TestCase):
    def test_server_session_and_correct_queue_shape(self):
        s=source('YandexWaveSession.swift')
        for token in ['radioSessionId','/rotor/session/new','/rotor/session/','"queue": Array(queue.suffix(1000))','unknownSession','terminated']:
            self.assertIn(token,s)
        self.assertNotIn('/rotor/station/',s)
    def test_settings_use_server_serialized_seeds(self):
        s=source('YandexWaveSession.swift')
        for token in ['/rotor/wave/settings','settingRestrictions','possibleValues','serializedSeed','unsupportedSetting']:
            self.assertIn(token,s)
        service=source('yandexmusicservice.swift')
        self.assertNotIn('"settingsChange"',service)
        self.assertNotIn('URLQueryItem(name: "diversity"',service)
    def test_refill_does_not_restart_session(self):
        s=source('yandexmusicservice.swift').split('func refillYandexWave()',1)[1].split('func getStationTracks',1)[0]
        self.assertIn('waveSession.next(excluding: history)',s)
        self.assertNotIn('startYandexWave(',s)
        core=source('playercore.swift').split('private func loadQueueContinuation',1)[1].split('private func flushListeningStats()',1)[0]
        self.assertIn('await ym.refillYandexWave()',core)
        self.assertNotIn('filterAndRankWave',core)
        self.assertIn('continuationLoader.load(key:key)',core)
    def test_server_order_without_chart_or_taste_fallback(self):
        s=source('yandexmusicservice.swift').split('func startYandexWave(',1)[1].split('/// Подборка',1)[0]
        for token in ['getChart(', 'personalPicks(', '.shuffled()', 'filterAndRankWave(']:self.assertNotIn(token,s)
        settings=source('WaveSettingsStore.swift').split('func reseedActiveWaveQueue',1)[1]
        self.assertNotIn('getChart(',settings)
        self.assertNotIn('filterAndRankWave',settings)
        self.assertIn('guard !tracks.isEmpty else {',settings)
        self.assertIn('service.appliedWaveSettings',settings)
    def test_no_radio_wrap_or_global_shuffle(self):
        s=source('playercore.swift').split('private func peekNext(auto:',1)[1].split('private func liveProgress()',1)[0]
        self.assertIn('if shuffle && !serverRadio',s)
        self.assertLess(s.index('if serverRadio { return nil }'),s.index('if repeatMode == .all'))
        finish=source('playercore.swift').split('private func handleTrackFinish()',1)[1].split('private var lastRefillCheck',1)[0]
        self.assertIn('repeatMode == .one && !isYandexWavePlayback',finish)
    def test_events_have_per_track_party_and_outbox(self):
        s=source('YandexWaveSession.swift')
        for token in ['playingContexts','batches[trackID]','"event": event, "batchId": context.batch','totalPlayedSeconds','feedbacks.removeFirst()','Feedback pending']:
            self.assertIn(token,s)
        service=source('yandexmusicservice.swift')
        self.assertNotIn('lastBatchId',service)
        remember=service.split('func remember(',1)[1].split('func isRecentlyPlayed',1)[0]
        self.assertNotIn('trackStarted',remember)
    def test_events_owned_by_actual_playback_not_view_or_seed(self):
        core=source('playercore.swift')
        self.assertIn('waveListening.finish(trackID: id)',core)
        self.assertIn('totalPlayedSeconds: seconds',core)
        self.assertIn('waveListening.sample(trackID: id',core)
        self.assertNotIn('reportSkip(',source('ActivePlayerPresentation.swift'))
        self.assertNotIn('rememberCurrentTrack',source('sonivoapp.swift'))
    def test_replacement_is_transactional_and_account_guarded(self):
        s=source('YandexWaveSession.swift')
        self.assertIn('generation == operation, canCommit()',s)
        service=source('yandexmusicservice.swift')
        for token in ['self.accountGeneration == account','self.trackStationRequestID == requestID','PlayerCore.shared.playbackRequestID == playback']:
            self.assertIn(token,service)
        self.assertIn('waveSession.reset()',service)
    def test_signed_in_mood_cards_use_server_not_local_sequencer(self):
        s=source('MoodRadioEngine.swift').split('func start(mood:',1)[1].split('let requestID = UUID()',1)[0]
        self.assertIn('if YandexMusicService.shared.isUserLoggedIn',s)
        self.assertIn('SonivoPlay.wave(station, forceFresh: true)',s)
    def test_expired_session_renews_only_when_server_reports_terminal(self):
        s=source('yandexmusicservice.swift')
        self.assertIn('items.isEmpty && waveSession.requiresRestart',s)
        self.assertIn('renewExpiredWave(session: session)',s)
        self.assertIn('settings: appliedWaveSettings ?? waveServerSettings',s)
        self.assertIn('waveSession.reset() // Discard the previous account',s)
    def test_ordinary_play_exits_radio_and_wave_play_keeps_it(self):
        core=source('playercore.swift')
        self.assertIn('if !radio && YandexMusicService.shared.activeStationId != nil',core)
        self.assertIn('finishWaveBeforeLeaving()',core)
        self.assertIn('router.play(first, queue: available, radio: true)',source('sonivocatalog.swift'))
        self.assertIn('waveSession.close()',source('yandexmusicservice.swift'))
    def test_recommendation_feedback_is_separate_from_favorites_and_precedes_skip(self):
        service=source('yandexmusicservice.swift')
        favorite=service.split('func reportWaveFavorite(',1)[1].split('func reportTrackStarted',1)[0]
        self.assertIn('isFavorite ? "like" : "unlike"',favorite)
        self.assertIn('isDisliked ? "dislike" : "undislike"',favorite)
        self.assertNotIn('/users/',favorite)
        self.assertIn('reportWaveFavorite(trackId: ymId, isFavorite: isFav)',source('librarystore.swift'))
        self.assertIn('reportWaveFavorite(trackId: ymId, isFavorite: true)',source('librarystore.swift'))
        core=source('playercore.swift')
        self.assertIn('waveListening.trackID == id ? waveListening.seconds : 0',core)
        player=source('PlayerScreenV2.swift').split('private var moreMenuButton',1)[1]
        self.assertLess(player.index('player.reportWaveDislike(current, isDisliked: true)'),player.index('player.next()'))
        self.assertIn('player.reportWaveDislike(current, isDisliked: false)',player)
        presentation=source('ActivePlayerPresentation.swift')
        self.assertIn('func reportWaveDislike(_ track: Track, isDisliked: Bool)',presentation)
        self.assertIn('legacy.reportWaveDislike(track, isDisliked: isDisliked)',presentation)
    def test_track_events_enforce_documented_required_fields(self):
        s=source('YandexWaveSession.swift').split('func event(type:',1)[1]
        self.assertIn('["trackFinished", "skip", "dislike"].contains(type)',s)
        self.assertIn('let played = seconds ?? 0',s)
        self.assertIn('played.isFinite ? played : 0',s)
        self.assertIn('!trackID.isEmpty',s)
    def test_wave_errors_are_visible_and_geometry_unchanged(self):
        self.assertIn('waveService.waveError',source('MyWaveHeroView.swift'))
        player=source('PlayerScreenV2.swift')
        self.assertIn('YandexMusicService.shared.waveError',player)
        self.assertIn('let standardArtworkStageHeight = min(totalWidth - 40, totalHeight * 0.44)',player)
if __name__=='__main__':unittest.main()
