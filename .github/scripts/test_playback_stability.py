"""Regression guards for app playback lifecycle and disposable internal audio cache.
These run on Linux; actual AVFoundation behavior still requires iOS testing.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

def source(name): return (ROOT / 'Sonivo' / name).read_text()
CORE = source('playercore.swift')

def block(begin, end): return CORE.split(begin, 1)[1].split(end, 1)[0]

class PlaybackStabilityTests(unittest.TestCase):
    def test_internal_audio_is_stored_in_bounded_caches_not_documents(self):
        cache = source('InternalAudioCache.swift')
        self.assertIn('.cachesDirectory', cache)
        self.assertIn('"PlaybackProcessing"', cache)
        self.assertIn('256 * 1_024 * 1_024', cache)
        self.assertIn('128 * 1_024 * 1_024', cache)
        self.assertIn('url != protectedURL', cache)
        migration = block('func migrateStreamToAudioEngineIfNeeded', 'private func scheduleTransitionIfNeeded')
        self.assertIn('InternalAudioCache.store', migration)
        self.assertNotIn('documentsDirectoryURL()', migration)
        self.assertNotIn('"vocal_', migration)
        self.assertIn('AVAudioFile(forReading: temporaryURL)', migration)
        self.assertIn('try Task.checkCancellation()', migration)

    def test_only_reserved_uuid_names_are_legacy_cache(self):
        cache = source('InternalAudioCache.swift')
        self.assertIn('stem.hasPrefix("vocal_")', cache)
        self.assertIn('UUID(uuidString: String(stem.dropFirst(6)))', cache)
        self.assertIn('InternalAudioCache.isLegacyFileName', source('MediaCacheManager.swift'))
        cleanup = block('private func removeLegacyUnboundedStreamCacheIfNeeded', 'private func configureSession')
        self.assertNotIn('guard !defaults.bool', cleanup)
        self.assertIn('InternalAudioCache.isLegacyFileName', cleanup)

    def test_library_filters_existing_index_and_future_scans(self):
        library = source('librarystore.swift')
        self.assertIn('removeInternalAudioEntries()', library)
        self.assertIn('tracks.removeAll(where: Self.isInternalAudioTrack)', library)
        self.assertIn('playlists[index].trackIds.removeAll', library)
        self.assertIn('playlists[index].cachedTracks.removeAll', library)
        self.assertIn('track.relativePath.isEmpty || track.relativePath == track.fileName', library)
        supported = library.split('private static func isSupportedAudioURL', 1)[1].split('private static func safeFileName', 1)[0]
        self.assertIn('!InternalAudioCache.isLegacyFileName', supported)
        self.assertIn('guard !isScanning else', library)

    def test_local_url_is_not_reconstructed_in_documents(self):
        start = block('private func start(at seconds:', 'private func startLocal')
        self.assertIn('fileURL: cachedURL', start)
        self.assertNotIn('localTrack.relativePath', start)
        local = block('private func startLocal', 'private func scheduleLocalSegment')
        self.assertIn('AVAudioFile(forReading: resolvedURL)', local)
        self.assertLess(local.index('guard !Task.isCancelled'), local.index('AVAudioFile(forReading: resolvedURL)'))
        self.assertLess(local.index('guard self.generation == token'), local.index('self.scheduleLocalSegment'))

    def test_completion_tokens_survive_pause_but_not_rescheduling(self):
        local = block('private func scheduleLocalSegment', 'private func startStream')
        self.assertIn('localSegmentTokens[key] == segmentToken', local)
        self.assertIn('self.activePlayer === node', local)
        self.assertNotIn('self.generation == token', local)
        pause = block('func pause()', 'func resume()')
        self.assertNotIn('localSegmentTokens.removeAll', pause)
        self.assertIn('engine.pause()', pause)

    def test_paused_local_seek_reschedules_actual_audio(self):
        seek = block('func seek(to seconds:', 'func stopAndClear')
        self.assertIn('guard seconds.isFinite', seek)
        self.assertIn('else if let file = activeAudioFile', seek)
        self.assertIn('scheduleLocalSegment(file, on: activePlayer, at: clamped)', seek)

    def test_resume_uses_actual_backend_and_migration_detaches_streams(self):
        resume = block('func resume()', 'func next()')
        self.assertIn('if isUsingStreamPlayer', resume)
        self.assertNotIn('if track.isStream', resume)
        local = block('private func startLocal', 'private func scheduleLocalSegment')
        self.assertIn('self.streamingPlayerA.replaceCurrentItem(with: nil)', local)
        self.assertIn('self.streamingPlayerB.replaceCurrentItem(with: nil)', local)
        self.assertIn('player.usesStreamingBackend ? 0', source('LyricsMatchPolicy.swift'))
        self.assertIn('PlayerCore.shared.usesStreamingBackend', source('streambeat.swift'))

    def test_crossfade_network_response_cannot_resurrect_canceled_deck(self):
        prep = block('private func scheduleSimpleTransition', 'private func stopBeatLoop')
        self.assertIn('transitionPreparationTask = Task', prep)
        self.assertIn('self.transitionRequestID == transitionID', prep)
        self.assertIn('!Task.isCancelled, self.generation == token', prep)
        self.assertLess(prep.index('guard !Task.isCancelled'), prep.index('targetStream.replaceCurrentItem'))
        cancel = block('private func cancelTransition()', 'func setOutgoingPlaybackRate')
        self.assertIn('transitionPreparationTask?.cancel()', cancel)
        self.assertIn('transitionRequestID = UUID()', cancel)

    def test_crossfade_is_frozen_on_pause_and_supports_mixed_backends(self):
        tick = block('private func tickTransition', 'private func legacyStreamingGainShaping')
        self.assertIn('guard isPlaying, let start', tick)
        prep = block('private func scheduleSimpleTransition', 'private func stopBeatLoop')
        self.assertNotIn('if isUsingStreamPlayer || nextTrack.isStream', prep)
        self.assertIn('if self.incomingIsStream', prep)
        complete = block('private func completeTransition', 'private func applyReverbPreset')
        self.assertIn('if incomingIsStream', complete)
        self.assertNotIn('if nextTrack.isStream || incomingIsStream', complete)
        self.assertIn('nativeIncomingPosition', complete)
        self.assertIn('startTimer()', complete)

    def test_background_does_not_claim_focus_when_paused(self):
        center = source('AutoMixV2NowPlayingCenter.swift').split('func setApplicationSceneActive', 1)[1].split('func install()', 1)[0]
        self.assertNotIn('activateForPlayback()', center)
        idle = block('func releaseAudioSessionIfIdle', 'private func setupStreamingPlayer')
        self.assertNotIn('currentTrack == nil', idle)
        self.assertIn('guard !isPlaying else', idle)
        self.assertIn('releaseAudioSessionIfIdle()', block('func pause()', 'func resume()'))

    def test_media_reset_rebuilds_objects_without_auto_resume(self):
        reset = block('func handleMediaServicesReset', 'func handleAudioRouteChange')
        self.assertIn('engine = AVAudioEngine()', reset)
        self.assertIn('streamingPlayerA = AVPlayer()', reset)
        self.assertIn('player.removeTimeObserver(token)', reset)
        self.assertNotIn('resume()', reset)
        session = source('playbackaudiosession.swift')
        self.assertIn('shouldResume && self.wasPlayingBeforeInterruption', session)
        self.assertIn('PlayerCore.shared.handleMediaServicesReset()', session)

    def test_old_sleep_fade_and_wave_refill_do_not_pause_or_start_new_track(self):
        fade = block('private func triggerSleepTimerExpiry', 'private var spectrumTapInstalled')
        self.assertIn('self.generation == fadeGeneration', fade)
        self.assertIn('self.sleepFadeRequestID == fadeID', fade)
        self.assertIn('self.generation == requestToken', block('func next()', 'func previous()'))
        catalog = source('sonivocatalog.swift')
        self.assertIn('catalogRequestID == request', catalog)
        self.assertIn('PlayerCore.shared.playbackRequestID == queuePlaybackRequest', catalog)

    def test_stream_quality_does_not_start_a_second_backend(self):
        quality = block('private func reapplyStreamQuality', 'private func beginStream')
        self.assertIn('isUsingStreamPlayer, isPlaying', quality)
        self.assertIn('self.qualityRequestID == request', quality)
        begin = block('private func beginStream', 'func findLocalOrCachedAudioFile')
        self.assertIn('playerA.stop()', begin)
        self.assertIn('playerB.stop()', begin)
        self.assertIn('isUsingStreamPlayer = true', begin)

    def test_video_is_opt_in_and_does_not_auto_save_to_phone(self):
        screen = source('PlayerScreenV2.swift')
        self.assertIn('"sonivo_videoshot_enabled") as? Bool ?? false', screen)
        load = screen.split('private func loadVideoShot()', 1)[1].split('private func setupVideoLooper', 1)[0]
        self.assertIn('guard isVideoShotEnabled, let track', load)
        self.assertNotIn('saveVideoLocally', load)
        self.assertNotIn('Task.detached', load)

    def test_internal_fader_never_modifies_phone_volume(self):
        fader = source('AntigravityTransitionManager.swift')
        self.assertIn('PlayerCore.shared.playbackRequestID == request', fader)
        self.assertIn('PlayerCore.shared.isPlaying else { return }', fader)
        self.assertNotIn('SystemVolumeManager', fader)
        self.assertNotIn('MPVolumeView', fader)

if __name__ == '__main__': unittest.main()
