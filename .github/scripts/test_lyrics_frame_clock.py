"""Frame scheduling, audio-clock reads and controls must remain display-only."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
def source(path): return (ROOT/'Sonivo'/path).read_text()

class LyricsFrameClockTests(unittest.TestCase):
    def test_requests_real_screen_promotions_and_dismantles(self):
        clock=source('LyricsDisplayClock.swift')
        for token in ['CADisplayLink(target:', 'preferredFrameRateRange = CAFrameRateRange(',
                      'screen.maximumFramesPerSecond', 'min(frameLimit, screen.maximumFramesPerSecond)',
                      'link.add(to: .main, forMode: .common)', 'weak var owner:',
                      'static func dismantleUIView', 'link?.invalidate()', 'guard running, let screen = view.window?.windowScene?.screen',
                      'let time = sampleTime()']:
            self.assertIn(token,clock)
        for forbidden in ['setActive(', 'activateForPlayback','time +', 'timestamp +', 'Timer(']:
            self.assertNotIn(forbidden,clock)
        self.assertIn('CADisableMinimumFrameDurationOnPhone: true',(ROOT/'project.yml').read_text())

    def test_only_current_word_reads_frame_time_and_power_lifecycle_is_bounded(self):
        view=source('TypographyLyricsView.swift')
        self.assertIn('active && TypographyLyricsPolicy.matchedWords(for: line) != nil ? clock.frameTime : 0',view)
        self.assertIn('private var activeIndex: Int? { frameClock.activeIndex }',view)
        self.assertIn('running: player.isPlaying && !player.isBuffering && lyrics.isSynchronized && scenePhase == .active && !reduceMotion',view)
        for token in ['thermal == .critical','lowPower || thermal == .serious ? 30 : 120',
                      'NSProcessInfoPowerStateDidChange','thermalStateDidChangeNotification',
                      '.onChange(of: settings.lyricsOffset)', '.onChange(of: player.isPlaying && !reduceMotion ? 0 : player.progress)']:
            self.assertIn(token,view)
        self.assertNotIn('currentTime +',view)

    def test_exact_audio_clock_and_seek_target_no_predicted_stall_time(self):
        core=source('playercore.swift')
        clock=core.split('var lyricsPresentationPosition: Double',1)[1].split('private var streamingTimeObservers',1)[0]
        self.assertIn('CMTimeGetSeconds(activeStreamingPlayer.currentTime())',clock)
        self.assertIn('guard isPlaying else',clock)
        self.assertIn('pending.track == currentTrack?.id, pending.generation == generation',clock)
        self.assertIn('return pending.seconds',clock)
        for forbidden in ['activateForPlayback','progress =','seek(to:','Date()']:
            self.assertNotIn(forbidden,clock)
        self.assertIn('self.lyricsSeekTarget?.id == seekID',core)
        self.assertIn('player.lyricsPresentationPosition - routeLatency(for: player) + offset',source('LyricsMatchPolicy.swift'))
        kinetic=source('KineticLyricsView.swift')
        self.assertIn('let smoothTime = sampleTime?() ?? currentTime',kinetic)
        self.assertNotIn('anchorTimestamp',kinetic)
        self.assertNotIn('currentTime + dt',kinetic)
        for file in ['TypographyLyricsView.swift','lyricsview.swift','PlayerScreenV2.swift','StaggeredLyricsView.swift']:
            self.assertIn('TypographyLyricsPolicy.activeIndex(',source(file))

    def test_controls_cancel_on_interaction_and_never_auto_hide_during_pause(self):
        player=source('PlayerScreenV2.swift')
        panel=player.split('private func lyricsControlsDeck',1)[1].split('private func artworkStage',1)[0]
        self.assertIn('.onChanged { _ in lyricsControlsHideTask?.cancel() }',panel)
        self.assertIn('.onEnded { _ in scheduleLyricsControlsHide() }',panel)
        self.assertIn('На паузе управление остаётся открытым',panel)
        self.assertIn('Label("Показать управление", systemImage: "chevron.up")',player)
        self.assertIn('lyricsControlsVisible = isEnabled',player)
        self.assertIn('.seconds(LyricsControlsPolicy.idleSeconds)',player)
        self.assertIn('guard !Task.isCancelled, canAutoHideLyricsControls else',player)
        self.assertIn('voiceOver: lyricsVoiceOver',player)
        self.assertNotIn('private func toggleLyricsControls()',player)
        hide = player.split('private func scheduleLyricsControlsHide()',1)[1].split('private func lyricsCoverCard',1)[0]
        self.assertNotIn('.seconds(3.5)',hide)
