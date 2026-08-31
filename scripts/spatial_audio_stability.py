from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
SESSION = ROOT / "Aurora" / "playbackaudiosession.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


player = PLAYER.read_text(encoding="utf-8")
player = replace_required(player,
'''    // MARK: - Audio Route Recovery

    func recoverAudioPipelineAfterRouteChange() {
        streamingPlayer.volume = volume
        if !isStreamingTransition {
            streamingMixPlayer.volume = 0
        }
        applyEQ()

        guard !isUsingStreamPlayer, currentTrack != nil else { return }''',
'''    // MARK: - Audio Route Recovery

    private func restoreSpatialPlaybackEligibility(rebuildStreamTaps: Bool) {
        if let primaryItem = streamingPlayer.currentItem {
            primaryItem.allowedAudioSpatializationFormats = .monoAndStereo
            if rebuildStreamTaps { StreamBeatTap.shared.attach(to: primaryItem) }
        }
        if let mixItem = streamingMixPlayer.currentItem {
            mixItem.allowedAudioSpatializationFormats = .monoAndStereo
            if rebuildStreamTaps { StreamBeatTap.shared.attach(to: mixItem) }
        }
    }

    func recoverSpatialAudioAfterCapabilityChange(enabled: Bool) {
        // The Fixed / Head Tracked choice belongs to iOS. Sonivo declares
        // stereo eligibility again and rebuilds the pre-effects EQ tap after
        // AirPods change the system spatialization mode.
        restoreSpatialPlaybackEligibility(rebuildStreamTaps: isUsingStreamPlayer)
        applyEQ()
        if enabled, isUsingStreamPlayer, isPlaying {
            streamingPlayer.play()
            if isStreamingTransition { streamingMixPlayer.play() }
        }
    }

    func recoverAudioPipelineAfterRouteChange() {
        streamingPlayer.volume = volume
        if !isStreamingTransition {
            streamingMixPlayer.volume = 0
        }
        restoreSpatialPlaybackEligibility(rebuildStreamTaps: isUsingStreamPlayer)
        applyEQ()

        guard !isUsingStreamPlayer, currentTrack != nil else { return }''', "spatial playback recovery")
PLAYER.write_text(player, encoding="utf-8")

session = SESSION.read_text(encoding="utf-8")
session = replace_required(session,
'''        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in''',
'''        observers.append(center.addObserver(
            forName: AVAudioSession.spatialPlaybackCapabilitiesChangedNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            let enabled = note.userInfo?[AVAudioSessionSpatialAudioEnabledKey] as? Bool ?? false
            Task { @MainActor in
                PlaybackAudioSessionCoordinator.shared.configure()
                PlayerCore.shared.recoverSpatialAudioAfterCapabilityChange(enabled: enabled)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in''', "spatial capability observer")
SESSION.write_text(session, encoding="utf-8")
print("AirPods Spatialize Stereo eligibility and route recovery applied.")
