"""Replace the metadata-guess AutoMix with the analysis-driven engine.

The planner in models.swift never listened to audio: it derived the blend length
from track duration and from words in the title, hard-coded 120 BPM, and capped
everything at 6 seconds. This patch routes PlayerCore through AutoMixEngine,
which fetches and analyses the next track ~45 s ahead, and makes the streaming
blend wait for readyToPlay so the incoming track is audible from the first
moment instead of buffering through the transition.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
MODELS = ROOT / "Aurora" / "models.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(label + ": required source anchor was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------- models.swift
# The 6 second ceiling makes the 10-30 second blends impossible, so raise the
# default and migrate previously stored small values.
models = MODELS.read_text(encoding="utf-8")

models = replace_required(
    models,
    "    var maxTransitionDuration: Double = 6.0 {",
    "    var maxTransitionDuration: Double = 18.0 {",
    "AutoMix duration ceiling",
)

models = replace_required(
    models,
    "        let dur = UserDefaults.standard.double(forKey: \"automix.maxDuration\")\n"
    "        if dur > 0 { maxTransitionDuration = dur }",
    "        let dur = UserDefaults.standard.double(forKey: \"automix.maxDuration\")\n"
    "        // Installs that stored the old 6 second ceiling would clamp every\n"
    "        // analysis-driven blend, so lift stale low values.\n"
    "        if dur > 0 { maxTransitionDuration = dur < 10 ? 18.0 : dur }",
    "AutoMix duration migration",
)

MODELS.write_text(models, encoding="utf-8")


# ------------------------------------------------------------ playercore.swift
player = PLAYER.read_text(encoding="utf-8")

# 1. Preparation state.
player = replace_required(
    player,
    "    private var currentAutoMixStyle: AutoMixStyle = .bassSwapBlend(duration: 3.5)\n",
    "    private var currentAutoMixStyle: AutoMixStyle = .bassSwapBlend(duration: 3.5)\n"
    "\n"
    "    // Analysis-driven AutoMix preparation\n"
    "    private var autoMixPlan: AutoMixTransitionPlan?\n"
    "    private var autoMixPreparedTrackId: UUID?\n"
    "    private var autoMixLocalURL: URL?\n"
    "    private var autoMixIncomingSkip: Double = 0\n"
    "    private var isPreparingAutoMix = false\n",
    "AutoMix preparation state",
)

# 2. Let the analysed plan override the metadata guess.
player = replace_required(
    player,
    r'''        let plan = AutoMixDJEngine.shared.planTransition(
            outgoing: current,
            outgoingDuration: totalDur,
            incoming: nextTrack,
            mode: transitionMode
        )
''',
    r'''        var plan = AutoMixDJEngine.shared.planTransition(
            outgoing: current,
            outgoingDuration: totalDur,
            incoming: nextTrack,
            mode: transitionMode
        )

        // When AutoMixEngine has actually listened to the audio, its cue point
        // and blend length replace the metadata guess.
        if transitionMode == .automix,
           let analysed = autoMixPlan,
           autoMixPreparedTrackId == nextTrack.id {
            plan.blendDuration = analysed.duration
            plan.cueTime = max(0, totalDur - analysed.leadTime)
            plan.style = analysed.style
        }
''',
    "analysis driven plan override",
)

# 3. Replace the 14 second metadata prebuffer with real early preparation.
player = replace_required(
    player,
    r'''        // 1. Pre-buffer incoming streaming track ahead of time (~10-12s before finish)
        if isUsingStreamPlayer || nextTrack.isStream {
            let prebufferThreshold = plan.blendDuration + 8.0
            let remaining = totalDur - currentPos
            if remaining <= prebufferThreshold && prebufferedTrackId != nextTrack.id && !isPrebufferingNextStream {
                isPrebufferingNextStream = true
                let ymID = Self.yandexTrackID(from: nextTrack)
                Task {
                    do {
                        let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                        let nextItem = AVPlayerItem(url: info.url)
                        StreamBeatTap.shared.attach(to: nextItem)
                        self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                        self.idleStreamingPlayer.volume = 0
                        self.idleStreamingPlayer.pause()
                        self.prebufferedTrackId = nextTrack.id
                        self.isPrebufferingNextStream = false
                    } catch {
                        self.isPrebufferingNextStream = false
                    }
                }
            }
        }

        guard currentPos >= plan.cueTime, (totalDur - currentPos) > 0.05 else { return }
''',
    r'''        // 1. Fetch and listen to the next track well ahead of the transition.
        let remaining = totalDur - currentPos
        if remaining <= AutoMixEngine.prepareLeadTime {
            prepareAutoMixIfNeeded(current: current, next: nextTrack, outgoingDuration: totalDur)
        }

        guard currentPos >= plan.cueTime, (totalDur - currentPos) > 0.05 else { return }
''',
    "analysis driven preparation",
)

# 4. Wait for readyToPlay before blending streams, and enter on music.
player = replace_required(
    player,
    r'''        if isUsingStreamPlayer || nextTrack.isStream {
            // Live Simultaneous Dual-Player Stream Blending
            if idleStreamingPlayer.currentItem == nil || prebufferedTrackId != nextTrack.id {
                let ymID = Self.yandexTrackID(from: nextTrack)
                Task {
                    do {
                        let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                        let nextItem = AVPlayerItem(url: info.url)
                        StreamBeatTap.shared.attach(to: nextItem)
                        self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                        self.idleStreamingPlayer.volume = 0
                        self.idleStreamingPlayer.seek(to: CMTime(seconds: 0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                        self.idleStreamingPlayer.play()
                        self.transitionStartTime = Date()
                        self.startTransitionTimer()
                    } catch {
                        self.isTransitioning = false
                        self.transitionScheduled = false
                        AutoMixDJEngine.shared.isTransitionActive = false
                    }
                }
            } else {
                idleStreamingPlayer.volume = 0
                idleStreamingPlayer.seek(to: CMTime(seconds: 0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                idleStreamingPlayer.play()
                transitionStartTime = Date()
                startTransitionTimer()
            }
            return
        }
''',
    r'''        if isUsingStreamPlayer || nextTrack.isStream {
            // Live simultaneous dual-player blending. The incoming deck is only
            // unmuted once it is genuinely ready, otherwise the first seconds of
            // every transition were silence while the stream buffered.
            let skip = autoMixIncomingSkip
            let localCopy = (autoMixPreparedTrackId == nextTrack.id) ? autoMixLocalURL : nil
            Task {
                do {
                    if self.idleStreamingPlayer.currentItem == nil || self.prebufferedTrackId != nextTrack.id {
                        let itemURL: URL
                        if let localCopy {
                            itemURL = localCopy
                        } else {
                            let ymID = Self.yandexTrackID(from: nextTrack)
                            let info = try await YandexMusicService.shared.getStreamInfo(for: ymID, preferredQuality: self.audioQuality, preferredBitrate: self.audioQuality.targetBitrate)
                            itemURL = info.url
                        }
                        let nextItem = AVPlayerItem(url: itemURL)
                        nextItem.preferredForwardBufferDuration = 6
                        StreamBeatTap.shared.attach(to: nextItem)
                        self.idleStreamingPlayer.replaceCurrentItem(with: nextItem)
                        self.prebufferedTrackId = nextTrack.id
                    }

                    self.idleStreamingPlayer.volume = 0

                    guard let item = self.idleStreamingPlayer.currentItem else {
                        self.abortStreamingBlend()
                        return
                    }
                    guard await self.awaitPlayable(item) else {
                        self.abortStreamingBlend()
                        return
                    }
                    guard self.isTransitioning else { return }

                    if skip > 0.4 {
                        await self.idleStreamingPlayer.seek(
                            to: CMTime(seconds: skip, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    } else {
                        await self.idleStreamingPlayer.seek(
                            to: .zero,
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }

                    guard self.isTransitioning else { return }
                    self.idleStreamingPlayer.play()
                    self.transitionStartTime = Date()
                    self.startTransitionTimer()
                } catch {
                    self.abortStreamingBlend()
                }
            }
            return
        }
''',
    "ready gated stream blend",
)

# 5. Helper methods.
player = replace_required(
    player,
    "    private func startTransitionTimer() {\n",
    r'''    // MARK: - Analysis-driven AutoMix preparation

    private func abortStreamingBlend() {
        isTransitioning = false
        transitionScheduled = false
        transitionStartTime = nil
        idleStreamingPlayer.pause()
        idleStreamingPlayer.volume = 0
        activeStreamingPlayer.volume = volume
        AutoMixDJEngine.shared.isTransitionActive = false
        AutoMixDJEngine.shared.transitionProgress = 0
    }

    private func awaitPlayable(_ item: AVPlayerItem, timeout: Double = 8.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if item.status == .readyToPlay { return true }
            if item.status == .failed { return false }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return item.status == .readyToPlay
    }

    /// Fetches the next track, listens to it, and builds a blend plan from the
    /// real audio of both sides of the mix.
    private func prepareAutoMixIfNeeded(current: Track, next: Track, outgoingDuration: Double) {
        guard transitionMode == .automix else { return }
        guard !isPreparingAutoMix else { return }
        guard autoMixPreparedTrackId != next.id else { return }

        isPreparingAutoMix = true
        let outgoingKey = Self.autoMixKey(for: current)
        let incomingKey = Self.autoMixKey(for: next)
        let preferredStyle = AutoMixDJEngine.shared.djStyle
        let maxDuration = AutoMixDJEngine.shared.maxTransitionDuration
        let quality = audioQuality

        Task {
            var incomingURL: URL? = next.isStream ? nil : next.url
            if incomingURL == nil {
                let direct = next.url
                if direct.scheme == "http" || direct.scheme == "https" {
                    incomingURL = direct
                } else {
                    let ymID = Self.yandexTrackID(from: next)
                    if let info = try? await YandexMusicService.shared.getStreamInfo(
                        for: ymID,
                        preferredQuality: quality,
                        preferredBitrate: quality.targetBitrate
                    ) {
                        incomingURL = info.url
                    }
                }
            }

            var incomingProfile: AutoMixProfile?
            var localCopy: URL?
            if let incomingURL {
                incomingProfile = await AutoMixEngine.shared.prepare(key: incomingKey, remoteURL: incomingURL)
                localCopy = await AutoMixEngine.shared.localFile(for: incomingKey)
            }

            // The outgoing track was analysed while it was the upcoming one.
            let outgoingProfile = await AutoMixEngine.shared.profile(for: outgoingKey)

            let built = AutoMixEngine.shared.plan(
                outgoing: outgoingProfile,
                incoming: incomingProfile,
                outgoingDuration: outgoingDuration,
                preferredStyle: preferredStyle,
                maxDuration: maxDuration
            )

            guard self.currentTrack?.id == current.id else {
                self.isPreparingAutoMix = false
                return
            }

            self.autoMixPlan = built
            self.autoMixPreparedTrackId = next.id
            self.autoMixLocalURL = localCopy
            self.autoMixIncomingSkip = built.incomingSkip
            self.isPreparingAutoMix = false
        }
    }

    private func clearAutoMixPreparation() {
        autoMixPlan = nil
        autoMixPreparedTrackId = nil
        autoMixLocalURL = nil
        autoMixIncomingSkip = 0
        isPreparingAutoMix = false
    }

    static func autoMixKey(for track: Track) -> String {
        let ym = yandexTrackID(from: track)
        return ym.isEmpty ? track.id.uuidString : ym
    }

    private func startTransitionTimer() {
''',
    "AutoMix preparation helpers",
)

# 6. Promote the real elapsed position instead of resetting progress to zero.
player = replace_required(
    player,
    r'''        incomingTrack = nil
        prebufferedTrackId = nil
        currentTrack = nextTrack
        streamDuration = nextTrack.duration
        anchorDate = Date()
        anchorOffset = 0
        pausedProgress = 0
        progress = 0
''',
    r'''        // The incoming deck has already been playing for the whole blend, so
        // resetting progress to zero desynchronised the scrubber and the
        // Now Playing timeline.
        var promoted: Double = 0
        if isUsingStreamPlayer {
            let elapsed = CMTimeGetSeconds(activeStreamingPlayer.currentTime())
            if elapsed.isFinite && elapsed > 0 { promoted = elapsed }
        } else {
            promoted = max(0, transitionDuration)
        }

        incomingTrack = nil
        prebufferedTrackId = nil
        clearAutoMixPreparation()
        currentTrack = nextTrack
        streamDuration = nextTrack.duration
        anchorDate = Date()
        anchorOffset = promoted
        pausedProgress = promoted
        progress = promoted
''',
    "promoted transition position",
)

# 7. A fresh manual start invalidates any pending preparation.
player = replace_required(
    player,
    r'''    private func beginStream(_ url: URL, at seconds: Double) {
        let item = AVPlayerItem(url: url)
''',
    r'''    private func beginStream(_ url: URL, at seconds: Double) {
        idleStreamingPlayer.pause()
        idleStreamingPlayer.replaceCurrentItem(with: nil)
        idleStreamingPlayer.volume = 0
        prebufferedTrackId = nil
        clearAutoMixPreparation()
        let item = AVPlayerItem(url: url)
''',
    "stream start resets preparation",
)

PLAYER.write_text(player, encoding="utf-8")
print("Analysis-driven AutoMix applied.")
