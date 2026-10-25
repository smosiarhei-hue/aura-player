"""Contract pinned to MarshalX/yandex-music-api 9ca132e5c18a72aab779c1fc68c169380a9357d0.
Actual request/feedback behavior is also executed by check_yandex_track_station on macOS.
"""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[2]
def source(name): return (R/'Sonivo'/name).read_text()
class WaveUpstreamParityTests(unittest.TestCase):
    def test_track_seed_does_not_restart_current_song(self):
        block=source('yandexmusicservice.swift').split('func startYandexTrackStation',1)[1].split('private func waveQueueHistory',1)[0]
        self.assertIn('startYandexWave(stationId: "track:',block)
        self.assertNotIn('seedID: seedID',block)
        player=source('PlayerScreenV2.swift').split('private func startTrackWave()',1)[1].split('private func startAIVibeWave',1)[0]
        self.assertIn('activateYandexTrackWave(tracks: waveTracks)',player)
        self.assertNotIn('router.play',player)
    def test_normal_defaults_start_from_base_seed_but_custom_filters_are_server_owned(self):
        block=source('YandexWaveSession.swift').split('private func seeds(',1)[1].split('/// Transactional',1)[0]
        self.assertLess(block.index('return [station]'),block.index('/rotor/wave/settings'))
        self.assertIn('serializedSeed',block)
        self.assertIn('throw Failure.unsupportedSetting(field)',block)
    def test_known_membership_is_retained_without_optional_batch_id(self):
        session=source('YandexWaveSession.swift')
        self.assertIn('batches[id] = BatchContext(id: batch.batchId)',session)
        self.assertIn('if let batchID = context.batch { payload["batchId"] = batchID }',session)
        self.assertIn('context = (serverID, batch.id)',session)
        self.assertNotIn('body: ["event": event, "batchId": context.batch]',session)
    def test_same_station_resume_does_not_fetch_or_replace_queue(self):
        block=source('sonivocatalog.swift').split('static func wave(',1)[1].split('static func album(',1)[0]
        resume=block.split('if !forceFresh',1)[1].split('if station.stationId == "app:recap"',1)[0]
        self.assertIn('service.activeStationId == station.stationId',resume)
        self.assertIn('router.play()',resume)
        self.assertIn('return',resume)
        self.assertNotIn('startYandexWave',resume)
        self.assertNotIn('replaceUpcomingQueue',block)
        self.assertIn('router.play(first, queue: available, radio: true)',block)
    def test_personal_wave_control_does_not_pause_an_unrelated_playlist_or_track_radio(self):
        home=source('SonivoHomeRedesignedView.swift').split('private func toggleWave()',1)[1].split('private func triggerShakeWave',1)[0]
        self.assertIn('let sameStation = ym.activeStationId == moodStation.stationId',home)
        self.assertIn('if sameStation && player.isPlaying',home)
        self.assertIn('SonivoPlay.wave(moodStation)',home)
        self.assertNotIn('forceFresh: true',home)
