from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


text = PLAYER.read_text(encoding="utf-8")

# 1. Prepared-transition state.
text = replace_required(
    text,
    "    private var streamingMixCodec: String?\n",
    """    private var streamingMixCodec: String?
    private var autoMixPlan: AutoMixPlan?
    private var autoMixPreparedTrackID: UUID?
    private var autoMixLocalURL: URL?
    private var autoMixOutgoingProfile: AutoMixProfile?
    private var autoMixOutgoingTrackID: UUID?
    private var autoMixPreparing = false
    private var pendingIncomingSkip: Double = 0
""",
    "AutoMix preparation state",
)

# 2. Analysis-driven timing instead of the old duration-bucket guesswork.
old_timing = """        let targetDuration: Double
        switch transitionMode {
        case .automix:
            if duration > 120 {
                targetDuration = 4.5
                currentAutoMixStyle = .bassSwapBlend(duration: 4.5)
            } else if duration > 45 {
                targetDuration = 3.0
                currentAutoMixStyle = .bassSwapBlend(duration: 3.0)
            } else {
                targetDuration = 1.5
                currentAutoMixStyle = .quickDrop(duration: 1.5)
            }
        case .crossfade:
            targetDuration = crossfadeDuration
            currentAutoMixStyle = .fadeOut(duration: crossfadeDuration)
        case .gapless:
            targetDuration = 0.1
            currentAutoMixStyle = .quickDrop(duration: 0.1)
        case .off:
            return
        }

        guard remaining <= targetDuration, remaining > 0 else { return }
        guard let nextTrack = peekNext(auto: true) else { return }
"""

new_timing = """        guard let nextTrack = peekNext(auto: true) else { return }

        let targetDuration: Double
        switch transitionMode {
        case .automix:
            // Listen to the upcoming track well before it is needed.
            prepareAutoMixIfNeeded(for: nextTrack, remaining: remaining)

            let prepared = autoMixPreparedTrackID == nextTrack.id ? autoMixPlan : nil
            let plan = prepared ?? AutoMixPlan.fallback(
                currentDuration: duration,
                nextDuration: nextTrack.duration
            )
            targetDuration = plan.leadTime
            pendingIncomingSkip = plan.incomingSkip
            currentAutoMixStyle = plan.style
        case .crossfade:
            targetDuration = crossfadeDuration
            pendingIncomingSkip = 0
            currentAutoMixStyle = .fadeOut(duration: crossfadeDuration)
        case .gapless:
            targetDuration = 0.1
            pendingIncomingSkip = 0
            currentAutoMixStyle = .quickDrop(duration: 0.1)
        case .off:
            return
        }

        guard remaining <= targetDuration, remaining > 0 else { return }
"""
text = replace_required(text, old_timing, new_timing, "analysis-driven transition timing")

# 3. Preparation pipeline.
prepare_methods = """    // MARK: - AutoMix preparation

    private func prepareAutoMixIfNeeded(for nextTrack: Track, remaining: Double) {
        guard transitionMode == .automix else { return }
        guard remaining <= AutoMixEngine.prepareLeadTime else { return }
        guard !autoMixPreparing, autoMixPreparedTrackID != nextTrack.id else { return }

        autoMixPreparing = true
        let token = generation
        let currentDuration = duration
        let outgoingTrack = currentTrack

        Task { [weak self] in
            guard let self else { return }

            // The outgoing side only needs measuring when it is a local file.
            var outgoingProfile = self.autoMixOutgoingProfile
            if let outgoingTrack,
               self.autoMixOutgoingTrackID != outgoingTrack.id,
               !outgoingTrack.isStream {
                outgoingProfile = await AutoMixEngine.shared.profile(
                    trackID: outgoingTrack.id,
                    url: outgoingTrack.url
                )
            } else if let outgoingTrack, self.autoMixOutgoingTrackID != outgoingTrack.id {
                outgoingProfile = await AutoMixEngine.shared.cachedProfile(trackID: outgoingTrack.id)
            }

            var sourceURL = nextTrack.url
            if nextTrack.isStream, let resolved = try? await self.streamingSource(for: nextTrack) {
                sourceURL = resolved.url
            }

            let preparation = await AutoMixEngine.shared.prepare(
                trackID: nextTrack.id,
                url: sourceURL,
                isRemote: nextTrack.isStream,
                currentProfile: outgoingProfile,
                currentDuration: currentDuration,
                nextDuration: nextTrack.duration
            )

            guard self.generation == token else {
                self.autoMixPreparing = false
                return
            }

            if let outgoingTrack {
                self.autoMixOutgoingTrackID = outgoingTrack.id
                self.autoMixOutgoingProfile = outgoingProfile
            }
            self.autoMixPreparedTrackID = nextTrack.id
            self.autoMixPlan = preparation.plan
            self.autoMixLocalURL = preparation.localURL
            self.autoMixPreparing = false
        }
    }

    private func clearAutoMixPreparation() {
        autoMixPlan = nil
        autoMixPreparedTrackID = nil
        autoMixLocalURL = nil
        pendingIncomingSkip = 0
    }

"""
text = replace_required(
    text,
    "    private func startTransitionTimer() {\n",
    prepare_methods + "    private func startTransitionTimer() {\n",
    "AutoMix preparation methods",
)

# 4. Play the prefetched local copy and trim the quiet intro on the stream deck.
text = replace_required(
    text,
    """                let item = AVPlayerItem(url: source.url)
                StreamBeatTap.shared.attach(to: item)
                streamingMixPlayer.pause()
                streamingMixPlayer.replaceCurrentItem(with: item)
                streamingMixPlayer.volume = 0
                streamingMixPlayer.play()
                startStreamingTransitionTimer()""",
    """                let preparedURL = autoMixPreparedTrackID == nextTrack.id ? autoMixLocalURL : nil
                let item = AVPlayerItem(url: preparedURL ?? source.url)
                item.preferredForwardBufferDuration = 4
                StreamBeatTap.shared.attach(to: item)
                streamingMixPlayer.pause()
                streamingMixPlayer.replaceCurrentItem(with: item)
                streamingMixPlayer.volume = 0
                let introSkip = pendingIncomingSkip
                if introSkip > 0.4 {
                    streamingMixPlayer.seek(
                        to: CMTime(seconds: introSkip, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: CMTime(seconds: 0.15, preferredTimescale: 600)
                    )
                }
                streamingMixPlayer.play()
                startStreamingTransitionTimer()""",
    "prepared incoming stream deck",
)

# 5. Trim the quiet intro on the local deck too.
text = replace_required(
    text,
    """                let frameCount = AVAudioFrameCount(nextFile.length)
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount,""",
    """                let incomingRate = nextFile.processingFormat.sampleRate
                let skipFrames = AVAudioFramePosition(max(0, self.pendingIncomingSkip) * incomingRate)
                let startFrame = max(0, min(skipFrames, max(nextFile.length - 1, 0)))
                let frameCount = AVAudioFrameCount(max(nextFile.length - startFrame, 1))
                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: startFrame, frameCount: frameCount,""",
    "local deck intro trim",
)

# 6. Shape the stream blend by style instead of one fixed equal-power curve.
text = replace_required(
    text,
    """        let outgoing = Float(cos(progress * .pi / 2)) * volume
        let incoming = Float(sin(progress * .pi / 2)) * volume""",
    """        let shaped = Self.blendCurve(for: currentAutoMixStyle, progress: progress)
        let outgoing = Float(shaped.outgoing) * volume
        let incoming = Float(shaped.incoming) * volume""",
    "styled stream blend",
)

curve_helper = """    /// Volume shapes for the streaming decks. `bassSwapBlend` holds the
    /// outgoing track up longer and then drops it, which is what makes the
    /// switch read as a deliberate DJ move rather than a fade.
    nonisolated static func blendCurve(
        for style: AutoMixStyle,
        progress: Double
    ) -> (outgoing: Double, incoming: Double) {
        let p = min(max(progress, 0), 1)
        switch style {
        case .bassSwapBlend:
            let hold = pow(cos(p * .pi / 2), 0.72)
            let rise = pow(sin(p * .pi / 2), 1.35)
            return (hold, rise)
        case .fadeOut:
            return (1 - p, p)
        case .quickDrop:
            let fast = min(1, p * 1.8)
            return (pow(cos(fast * .pi / 2), 1.4), pow(sin(fast * .pi / 2), 0.85))
        }
    }

"""
text = replace_required(
    text,
    "    private func tickStreamingTransition() {\n",
    curve_helper + "    private func tickStreamingTransition() {\n",
    "blend curve helper",
)

# 7. Reset preparation once a transition has completed.
text = replace_required(
    text,
    """        streamingMixTrack = nil
        streamingMixBitrate = nil
        streamingMixCodec = nil
        transitionStartTime = nil""",
    """        streamingMixTrack = nil
        streamingMixBitrate = nil
        streamingMixCodec = nil
        autoMixOutgoingTrackID = nextTrack.id
        autoMixOutgoingProfile = nil
        clearAutoMixPreparation()
        transitionStartTime = nil""",
    "reset preparation after transition",
)

PLAYER.write_text(text, encoding="utf-8")
print("Analysis-driven AutoMix applied.")
