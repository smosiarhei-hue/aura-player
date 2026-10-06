"""Regression checks for the native background and bounded streaming capture."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PrismaticBurstTests(unittest.TestCase):
    def test_shader_retains_source_ray_march_and_credit(self):
        text = (ROOT / 'Sonivo/PrismaticBurst.metal').read_text()
        self.assertIn('half4 prismaticBurst', text)
        self.assertIn('i < 44', text)
        self.assertIn('marchT += stepLen', text)
        self.assertIn('prismaticRotZ', text)
        self.assertIn('React Bits', text)
        self.assertIn('Commons Clause', text)
        self.assertIn('col = clamp(col, 0.0f, 1.0f)', text)

    def test_background_reads_real_audio_not_a_fake_bpm(self):
        text = (ROOT / 'Sonivo/PrismaticBurstBackground.swift').read_text()
        self.assertIn('analyzer.kick', text)
        self.assertIn('analyzer.bass', text)
        self.assertIn('analyzer.mids', text)
        self.assertIn('analyzer.lastAudioSampleTime < 0.4', text)
        for fake in ('dynamicKick', 'dynamicBass', 'tempo', '120.0', 'player.progress'):
            self.assertNotIn(fake, text)

    def test_scene_pause_accessibility_and_render_budget(self):
        text = (ROOT / 'Sonivo/PrismaticBurstBackground.swift').read_text()
        for token in ('isOnScreen && isPlaying && isVisible && !reduceMotion', 'scenePhase == .active',
                      'paused: !running', 'isLowPowerModeEnabled', 'width * 0.5', '1 / 30.0',
                      'onDisappear { isOnScreen = false', '.allowsHitTesting(false)'):
            self.assertIn(token, text)

    def test_home_uses_one_fullscreen_background_not_an_artwork_aura(self):
        home = (ROOT / 'Sonivo/SonivoHomeRedesignedView.swift').read_text()
        hero = (ROOT / 'Sonivo/MyWaveHeroView.swift').read_text()
        self.assertIn('PrismaticBurstBackground(', home)
        self.assertLess(home.index('PrismaticBurstBackground('), home.index('ScrollView(showsIndicators: false)'))
        self.assertNotIn('atmosphericAuraBackdrop', hero)
        self.assertNotIn('rotation3DEffect', hero)
        self.assertIn('!showPlayer && !showSettings && !showAIAssistant && !showShakeOverlay', home)

    def test_audio_callbacks_are_c_and_never_download_files(self):
        c = (ROOT / 'Packages/StreamAudioProbe/Sources/StreamAudioProbe/StreamAudioProbe.c').read_text()
        swift = (ROOT / 'Sonivo/streambeat.swift').read_text()
        self.assertIn('.process = probeProcess', c)
        self.assertIn('MTAudioProcessingTapGetSourceAudio', c)
        self.assertIn('import StreamAudioProbe', swift)
        for token in ('URLSession', 'download(', 'FileManager', 'documentsDirectoryURL'):
            self.assertNotIn(token, swift)
        self.assertNotIn('MTAudioProcessingTapCallbacks', swift)

    def test_capture_memory_is_fixed_and_process_does_not_block_or_allocate(self):
        c = (ROOT / 'Packages/StreamAudioProbe/Sources/StreamAudioProbe/StreamAudioProbe.c').read_text()
        self.assertIn('#define PROBE_FRAMES 1024', c)
        process = c.split('static void probeProcess', 1)[1].split('MTAudioProcessingTapRef SonivoStreamProbeCreate', 1)[0]
        self.assertIn('atomic_flag_test_and_set_explicit', process)
        for token in ('calloc', 'malloc', 'pthread_mutex_lock', 'dispatch_sync', 'sleep('):
            self.assertNotIn(token, process)
        self.assertIn('buffers->mBuffers[b]', process)
        self.assertIn('buffer->mNumberChannels', process)
        self.assertIn('offset < length', process)
        self.assertIn('isfinite(data[offset])', process)
        self.assertNotIn('data[offset] =', process)

    def test_only_audible_deck_drives_stream_spectrum_and_stale_signal_resets(self):
        swift = (ROOT / 'Sonivo/streambeat.swift').read_text()
        self.assertIn('PlayerCore.shared.streamingPlayer.currentItem', swift)
        self.assertIn('PlayerCore.shared.currentTrack?.isStream == true', swift)
        self.assertIn('self.readSpectrum(from: self.probes[key]?.tap)', swift)
        self.assertIn('Date.timeIntervalSinceReferenceDate - lastSignal > 0.5', swift)
        self.assertIn('SpectrumAnalyzer.ingest(buffer: buffer', swift)

    def test_c_target_is_linked_and_license_is_shipped(self):
        project = (ROOT / 'project.yml').read_text()
        package = (ROOT / 'Packages/StreamAudioProbe/Package.swift').read_text()
        self.assertIn('path: Packages/StreamAudioProbe', project)
        self.assertIn('product: StreamAudioProbe', project)
        self.assertIn('.linkedFramework("MediaToolbox")', package)
        license_text = (ROOT / 'Sonivo/ThirdPartyNotices.txt').read_text()
        self.assertIn('Copyright (c) 2026 David Haz', license_text)
        self.assertIn('Commons Clause', license_text)

    def test_kick_is_an_onset_not_a_constant_sustained_bass(self):
        text = (ROOT / 'Sonivo/spectrumanalyzer.swift').read_text()
        self.assertIn('onset > max(0.015, previousBaseline * 0.08)', text)
        self.assertIn('kickEnvelope = max(gated, kickEnvelope * 0.82)', text)
        self.assertIn('lastAudioSampleTime = 0', text)


if __name__ == '__main__':
    unittest.main()
