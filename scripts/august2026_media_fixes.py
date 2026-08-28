from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
SESSION = ROOT / "Aurora" / "playbackaudiosession.swift"
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"

def replace_required(text, old, new, label):
    if new in text: return text
    if old not in text: raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)

player = PLAYER.read_text(encoding="utf-8")
player = replace_required(player,
'''    private var streamingPlayer = AVPlayer()
    private var streamingMixPlayer = AVPlayer()
    private var timeObserverToken: Any?''',
'''    private var streamingPlayer = AVPlayer()
    private var streamingMixPlayer = AVPlayer()
    private lazy var systemNowPlayingSession = MPNowPlayingSession(players: [streamingPlayer, streamingMixPlayer])
    private var timeObserverToken: Any?''', "MPNowPlayingSession")
player = replace_required(player,
'''        UIApplication.shared.beginReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info''',
'''        UIApplication.shared.beginReceivingRemoteControlEvents()
        systemNowPlayingSession.isActive = true
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info''', "active Now Playing session")
player = replace_required(player,
'''    private func applyEQ() {
        for (i, band) in eqNodeA.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
        for (i, band) in eqNodeB.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
    }''',
'''    private func applyEQ() {
        for (i, band) in eqNodeA.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
        for (i, band) in eqNodeB.bands.enumerated() { band.gain = eqEnabled ? eqGains[i] : 0 }
        StreamBeatTap.shared.updateEQ(enabled: eqEnabled, gains: eqGains)
    }''', "stream EQ state")
player = replace_required(player,
'''        if isUsingStreamPlayer {
            let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
            streamingPlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            pausedProgress = clamped
            anchorOffset = clamped
            if isPlaying {
                start(at: clamped)
            }
        }
        updateNowPlayingInfo()
        persistPlaybackState(force: true)''',
'''        if isUsingStreamPlayer {
            generation += 1
            let seekGeneration = generation
            let targetTime = CMTime(seconds: clamped, preferredTimescale: 600)
            let observedPlayer = streamingPlayer
            let shouldResume = isPlaying
            observedPlayer.currentItem?.cancelPendingSeeks()
            observedPlayer.seek(to: targetTime,
                toleranceBefore: CMTime(seconds: 0.20, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.20, preferredTimescale: 600)) { [weak self, weak observedPlayer] finished in
                Task { @MainActor [weak self, weak observedPlayer] in
                    guard finished, let self, let observedPlayer,
                          self.generation == seekGeneration,
                          self.streamingPlayer === observedPlayer else { return }
                    let actual = CMTimeGetSeconds(observedPlayer.currentTime())
                    self.progress = actual.isFinite ? max(0, actual) : clamped
                    if shouldResume { observedPlayer.play() }
                    self.updateNowPlayingInfo()
                    self.persistPlaybackState(force: true)
                }
            }
            return
        } else {
            pausedProgress = clamped
            anchorOffset = clamped
            if isPlaying { start(at: clamped) }
        }
        updateNowPlayingInfo()
        persistPlaybackState(force: true)''', "single-flight seeking")
PLAYER.write_text(player, encoding="utf-8")

session = SESSION.read_text(encoding="utf-8")
session = replace_required(session,
'''            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)''',
'''            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setIsNowPlayingCandidate(true)
            try session.setActive(true)''', "iOS 26 Now Playing candidacy")
SESSION.write_text(session, encoding="utf-8")

screen = SCREEN.read_text(encoding="utf-8")
screen = replace_required(screen, '''    @State private var trackWaveMessage: String?
''', '''    @State private var trackWaveMessage: String?
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
''', "scrubbing state")
screen = replace_required(screen,
'''            Slider(
                value: Binding(get: { player.progress }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.01)
            )''',
'''            Slider(
                value: Binding(get: { isScrubbing ? scrubPosition : player.progress }, set: { scrubPosition = $0 }),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    if editing { scrubPosition = player.progress; isScrubbing = true }
                    else { let target = scrubPosition; isScrubbing = false; player.seek(to: target) }
                }
            )''', "single-commit scrubber")
screen = replace_required(screen,
'''                Text(player.formatted(player.progress))
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - player.progress)))''',
'''                let displayedProgress = isScrubbing ? scrubPosition : player.progress
                Text(player.formatted(displayedProgress))
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - displayedProgress)))''', "scrubber labels")
SCREEN.write_text(screen, encoding="utf-8")
print("iOS 26 Now Playing session, stable seeking, stream EQ, and scrubber applied.")
