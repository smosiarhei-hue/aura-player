from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
text = PLAYER.read_text(encoding="utf-8")

# A single AVPlayer cannot overlap two streams. Add a second deck that is
# preloaded with the next URL and promoted to the active deck after a true
# equal-power crossfade.
old_player = '''    private let streamingPlayer = AVPlayer()
    private var timeObserverToken: Any?
'''
new_player = '''    private var streamingPlayer = AVPlayer()
    private var streamingMixPlayer = AVPlayer()
    private var timeObserverToken: Any?
'''
if new_player not in text:
    if old_player not in text:
        print("[patch-skip] " + str("Streaming player declaration was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(old_player, new_player, 1)

state_anchor = '''    private var currentAutoMixStyle: AutoMixStyle = .bassSwapBlend(duration: 3.5)
'''
state_block = '''    private var currentAutoMixStyle: AutoMixStyle = .bassSwapBlend(duration: 3.5)
    private var isStreamingTransition = false
    private var streamingMixTrack: Track?
    private var streamingMixBitrate: Int?
    private var streamingMixCodec: String?
'''
if state_block not in text:
    if state_anchor not in text:
        print("[patch-skip] " + str("AutoMix state anchor was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(state_anchor, state_block, 1)

# Move the active deck observer into a reinstallable helper, because the two
# AVPlayer references swap after every transition.
helper_marker = '''    private func installStreamingTimeObserver() {
'''
if helper_marker not in text:
    observer_start_marker = '''        let interval = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)
'''
    notification_marker = '''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime'''
    start = text.find(observer_start_marker)
    end = text.find(notification_marker, start)
    if start < 0 or end < 0:
        print("[patch-skip] " + str("Streaming time observer block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)

    setup_replacement = '''        streamingMixPlayer.automaticallyWaitsToMinimizeStalling = false
        streamingMixPlayer.volume = 0
        installStreamingTimeObserver()

'''
    text = text[:start] + setup_replacement + text[end:]

    setup_audio_anchor = '''    private func setupAudioEngine() {
'''
    observer_helper = '''    private func installStreamingTimeObserver() {
        let observedPlayer = streamingPlayer
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserverToken = observedPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak observedPlayer] time in
            Task { @MainActor [weak self, weak observedPlayer] in
                guard let self,
                      let observedPlayer,
                      self.streamingPlayer === observedPlayer,
                      self.isUsingStreamPlayer,
                      self.isPlaying else { return }

                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite && seconds >= 0 {
                    self.progress = seconds

                    if let item = observedPlayer.currentItem {
                        let itemDuration = CMTimeGetSeconds(item.duration)
                        if itemDuration.isFinite && itemDuration > 0 && self.streamDuration != itemDuration {
                            self.streamDuration = itemDuration
                        }
                    }

                    self.scheduleTransitionIfNeeded()
                    self.updateNowPlayingInfo()
                    self.persistPlaybackState()
                }
            }
        }
    }

'''
    if setup_audio_anchor not in text:
        print("[patch-skip] " + str("Audio engine anchor was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(setup_audio_anchor, observer_helper + setup_audio_anchor, 1)

# Pause and clear both stream decks.
pause_old = '''        if isUsingStreamPlayer {
            streamingPlayer.pause()
        } else {'''
pause_new = '''        if isUsingStreamPlayer {
            streamingPlayer.pause()
            streamingMixPlayer.pause()
        } else {'''
if pause_new not in text:
    if pause_old not in text:
        print("[patch-skip] " + str("Streaming pause block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(pause_old, pause_new, 1)

clear_old = '''        streamingPlayer.pause()
        streamingPlayer.replaceCurrentItem(with: nil)
        playerA.stop()'''
clear_new = '''        streamingPlayer.pause()
        streamingPlayer.replaceCurrentItem(with: nil)
        streamingMixPlayer.pause()
        streamingMixPlayer.replaceCurrentItem(with: nil)
        streamingMixPlayer.volume = 0
        playerA.stop()'''
if clear_new not in text:
    if clear_old not in text:
        print("[patch-skip] " + str("Streaming clear block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(clear_old, clear_new, 1)

begin_old = '''    private func beginStream(_ url: URL, at seconds: Double) {
        let item = AVPlayerItem(url: url)
        StreamBeatTap.shared.attach(to: item)
        streamingPlayer.replaceCurrentItem(with: item)'''
begin_new = '''    private func beginStream(_ url: URL, at seconds: Double) {
        streamingMixPlayer.pause()
        streamingMixPlayer.replaceCurrentItem(with: nil)
        streamingMixPlayer.volume = 0
        streamingPlayer.volume = volume
        let item = AVPlayerItem(url: url)
        StreamBeatTap.shared.attach(to: item)
        streamingPlayer.replaceCurrentItem(with: item)'''
if begin_new not in text:
    if begin_old not in text:
        print("[patch-skip] " + str("beginStream block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(begin_old, begin_new, 1)

old_stream_transition = '''        // Progressive stream transitions
        if isUsingStreamPlayer || nextTrack.isStream {
            transitionScheduled = true
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self, self.generation == token else { return }
                self.isTransitioning = false
                self.currentTrack = nextTrack
                self.start(at: 0) // transitionScheduled cleared in beginStream
            }
            return
        }
'''
new_stream_transition = '''        // True dual-deck crossfade for two online streams.
        if isUsingStreamPlayer && nextTrack.isStream {
            transitionScheduled = true
            prepareStreamingTransition(to: nextTrack, requestedDuration: targetDuration, token: generation)
            return
        }

        // Mixed local/online queues use a reliable end switch.
        if isUsingStreamPlayer || nextTrack.isStream {
            transitionScheduled = true
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self, self.generation == token else { return }
                self.isTransitioning = false
                self.transitionScheduled = false
                self.currentTrack = nextTrack
                self.start(at: 0)
            }
            return
        }
'''
if new_stream_transition not in text:
    if old_stream_transition not in text:
        print("[patch-skip] " + str("Old progressive transition block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(old_stream_transition, new_stream_transition, 1)

streaming_methods_marker = '''    private func prepareStreamingTransition(
'''
if streaming_methods_marker not in text:
    timer_anchor = '''    private func startTransitionTimer() {
'''
    streaming_methods = '''    private func prepareStreamingTransition(
        to nextTrack: Track,
        requestedDuration: Double,
        token: Int
    ) {
        Task {
            do {
                let source = try await streamingSource(for: nextTrack)
                guard generation == token,
                      currentTrack?.id != nextTrack.id,
                      isUsingStreamPlayer,
                      isPlaying else {
                    transitionScheduled = false
                    return
                }

                let remaining = max(0, duration - progress)
                guard remaining > 0.15 else {
                    transitionScheduled = false
                    currentTrack = nextTrack
                    start(at: 0)
                    return
                }

                streamingMixTrack = nextTrack
                streamingMixBitrate = source.bitrate
                streamingMixCodec = source.codec
                transitionDuration = min(max(requestedDuration, 0.25), remaining)
                transitionStartTime = Date()
                isTransitioning = true
                isStreamingTransition = true

                let item = AVPlayerItem(url: source.url)
                StreamBeatTap.shared.attach(to: item)
                streamingMixPlayer.pause()
                streamingMixPlayer.replaceCurrentItem(with: item)
                streamingMixPlayer.volume = 0
                streamingMixPlayer.play()
                startStreamingTransitionTimer()
            } catch {
                guard generation == token else { return }
                transitionScheduled = false
                isTransitioning = false
                isStreamingTransition = false
            }
        }
    }

    private func streamingSource(for track: Track) async throws -> (url: URL, bitrate: Int?, codec: String?) {
        let candidate = track.url
        if candidate.scheme == "http" || candidate.scheme == "https" {
            return (candidate, 128, "mp3")
        }

        let info = try await YandexMusicService.shared.getStreamInfo(
            for: Self.yandexTrackID(from: track),
            preferredBitrate: audioQuality.targetBitrate
        )
        return (info.url, info.bitrate, info.codec)
    }

    private func startStreamingTransitionTimer() {
        transitionTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickStreamingTransition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        transitionTimer = timer
    }

    private func tickStreamingTransition() {
        guard isStreamingTransition,
              isTransitioning,
              let start = transitionStartTime else { return }

        let elapsed = -start.timeIntervalSinceNow
        let progress = min(max(elapsed / max(transitionDuration, 0.01), 0), 1)
        let outgoing = Float(cos(progress * .pi / 2)) * volume
        let incoming = Float(sin(progress * .pi / 2)) * volume
        streamingPlayer.volume = outgoing
        streamingMixPlayer.volume = incoming

        if progress >= 1 {
            completeStreamingTransition()
        }
    }

    private func completeStreamingTransition() {
        guard let nextTrack = streamingMixTrack else {
            cancelTransition()
            return
        }

        transitionTimer?.invalidate()
        transitionTimer = nil

        if let observer = timeObserverToken {
            streamingPlayer.removeTimeObserver(observer)
            timeObserverToken = nil
        }

        let outgoingPlayer = streamingPlayer
        streamingPlayer = streamingMixPlayer
        streamingMixPlayer = outgoingPlayer

        streamingMixPlayer.pause()
        streamingMixPlayer.replaceCurrentItem(with: nil)
        streamingMixPlayer.volume = 0
        streamingPlayer.volume = volume

        generation += 1
        currentTrack = nextTrack
        currentBitrate = streamingMixBitrate
        currentCodec = streamingMixCodec
        streamDuration = nextTrack.duration
        let promotedTime = CMTimeGetSeconds(streamingPlayer.currentTime())
        progress = promotedTime.isFinite ? max(0, promotedTime) : 0
        isUsingStreamPlayer = true
        isPlaying = true

        streamingMixTrack = nil
        streamingMixBitrate = nil
        streamingMixCodec = nil
        transitionStartTime = nil
        isStreamingTransition = false
        isTransitioning = false
        transitionScheduled = false

        installStreamingTimeObserver()
        updateNowPlayingInfo()
        persistPlaybackState(force: true)
    }

'''
    if timer_anchor not in text:
        print("[patch-skip] " + str("Transition timer anchor was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(timer_anchor, streaming_methods + timer_anchor, 1)

cancel_old = '''    private func cancelTransition() {
        transitionScheduled = false
        guard isTransitioning else { return }
        transitionTimer?.invalidate()'''
cancel_new = '''    private func cancelTransition() {
        transitionScheduled = false

        if isStreamingTransition {
            transitionTimer?.invalidate()
            transitionTimer = nil
            transitionStartTime = nil
            streamingMixPlayer.pause()
            streamingMixPlayer.replaceCurrentItem(with: nil)
            streamingMixPlayer.volume = 0
            streamingPlayer.volume = volume
            streamingMixTrack = nil
            streamingMixBitrate = nil
            streamingMixCodec = nil
            isStreamingTransition = false
            isTransitioning = false
            return
        }

        guard isTransitioning else { return }
        transitionTimer?.invalidate()'''
if cancel_new not in text:
    if cancel_old not in text:
        print("[patch-skip] " + str("cancelTransition block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(cancel_old, cancel_new, 1)

PLAYER.write_text(text, encoding="utf-8")
print("Dual-deck streaming AutoMix applied.")
