from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
SESSION = ROOT / "Aurora" / "playbackaudiosession.swift"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


text = PLAYER.read_text(encoding="utf-8")

if "import UIKit\n" not in text:
    text = replace_required(
        text,
        "import SwiftUI\n",
        "import SwiftUI\nimport UIKit\n",
        "UIKit import",
    )

# Keep both AVPlayer decks coherent when the user changes volume.
text = replace_required(
    text,
    '''        didSet {
            streamingPlayer.volume = volume
            engine.mainMixerNode.outputVolume = volume
            defaults.set(volume, forKey: "player.volume")
        }''',
    '''        didSet {
            streamingPlayer.volume = volume
            if !isStreamingTransition {
                streamingMixPlayer.volume = 0
            }
            engine.mainMixerNode.outputVolume = volume
            defaults.set(volume, forKey: "player.volume")
        }''',
    "dual-deck volume",
)

# Publish stable system-media identity and explicitly register the app as the
# current remote-control receiver. iOS owns the actual Lock Screen/Dynamic
# Island tap, but these values let it reliably route that tap back to Sonivo.
text = replace_required(
    text,
    '''        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }''',
    '''        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }''',
    "Now Playing stopped state",
)

text = replace_required(
    text,
    '''            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]''',
    '''            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id.uuidString,
            MPNowPlayingInfoPropertyPlaybackQueueIdentifier: "com.smoze.sonivo.playback"
        ]''',
    "Now Playing media identity",
)

text = replace_required(
    text,
    '''        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Fetch remote artwork once per track, then cache (prevents flicker)''',
    '''        UIApplication.shared.beginReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        // Fetch remote artwork once per track, then cache (prevents flicker)''',
    "Now Playing remote-control registration",
)

# Cancel a half-finished stream blend before pausing. Otherwise its timer can
# promote the silent incoming deck and mark playback active while paused.
text = replace_required(
    text,
    '''        if isUsingStreamPlayer {
            streamingPlayer.pause()
            streamingMixPlayer.pause()
        } else {''',
    '''        if isUsingStreamPlayer {
            if isStreamingTransition {
                cancelTransition()
            }
            streamingPlayer.pause()
            streamingMixPlayer.pause()
        } else {''',
    "AutoMix pause cancellation",
)

# Resolve the next URL slightly before the audible transition and wait until
# AVPlayerItem is ready. Previously the fade timer started while the second
# deck was still buffering, producing silence or a hard switch.
text = replace_required(
    text,
    '''        guard remaining <= targetDuration, remaining > 0 else { return }
        guard let nextTrack = peekNext(auto: true) else { return }
''',
    '''        guard let nextTrack = peekNext(auto: true) else { return }
        let preparationLead = (isUsingStreamPlayer && nextTrack.isStream) ? 3.0 : 0.0
        guard remaining <= targetDuration + preparationLead, remaining > 0 else { return }
''',
    "AutoMix preparation lead",
)

old_prepare = '''                streamingMixTrack = nextTrack
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
                startStreamingTransitionTimer()'''
new_prepare = '''                let item = AVPlayerItem(url: source.url)
                StreamBeatTap.shared.attach(to: item)
                streamingMixPlayer.pause()
                streamingMixPlayer.replaceCurrentItem(with: item)
                streamingMixPlayer.volume = 0

                for _ in 0..<40 {
                    if item.status == .readyToPlay || item.status == .failed { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    guard generation == token,
                          currentTrack?.id != nextTrack.id,
                          isUsingStreamPlayer,
                          isPlaying else {
                        streamingMixPlayer.replaceCurrentItem(with: nil)
                        transitionScheduled = false
                        return
                    }
                }

                guard item.status == .readyToPlay else {
                    streamingMixPlayer.replaceCurrentItem(with: nil)
                    transitionScheduled = false
                    isTransitioning = false
                    isStreamingTransition = false
                    return
                }

                let preparedRemaining = max(0, duration - progress)
                let delay = max(0, preparedRemaining - requestedDuration)
                if delay > 0.05 {
                    try? await Task.sleep(for: .seconds(delay))
                }

                guard generation == token,
                      currentTrack?.id != nextTrack.id,
                      isUsingStreamPlayer,
                      isPlaying else {
                    streamingMixPlayer.replaceCurrentItem(with: nil)
                    transitionScheduled = false
                    return
                }

                let finalRemaining = max(0, duration - progress)
                guard finalRemaining > 0.15 else {
                    streamingMixPlayer.replaceCurrentItem(with: nil)
                    transitionScheduled = false
                    currentTrack = nextTrack
                    start(at: 0)
                    return
                }

                streamingMixTrack = nextTrack
                streamingMixBitrate = source.bitrate
                streamingMixCodec = source.codec
                transitionDuration = min(max(requestedDuration, 0.25), finalRemaining)
                transitionStartTime = Date()
                isTransitioning = true
                isStreamingTransition = true
                streamingMixPlayer.play()
                startStreamingTransitionTimer()'''
text = replace_required(text, old_prepare, new_prepare, "buffer-aware streaming AutoMix")

# Reapply EQ and restart the local engine after wired/Bluetooth route changes.
# This targets the headphone failure without reintroducing the unsafe
# MTAudioProcessingTap that previously crashed stream playback.
route_method = '''    // MARK: - Audio Route Recovery

    func recoverAudioPipelineAfterRouteChange() {
        streamingPlayer.volume = volume
        if !isStreamingTransition {
            streamingMixPlayer.volume = 0
        }
        applyEQ()

        guard !isUsingStreamPlayer, currentTrack != nil else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        if isPlaying {
            activePlayer.play()
        }
    }

'''
route_anchor = "    // MARK: - Sleep Timer\n"
if route_method not in text:
    if route_anchor not in text:
        raise RuntimeError("audio route recovery: insertion anchor was not found")
    text = text.replace(route_anchor, route_method + route_anchor, 1)

PLAYER.write_text(text, encoding="utf-8")

session = SESSION.read_text(encoding="utf-8")
old_call = "                PlaybackAudioSessionCoordinator.shared.configure()"
new_call = '''                PlaybackAudioSessionCoordinator.shared.configure()
                PlayerCore.shared.recoverAudioPipelineAfterRouteChange()'''
if new_call not in session:
    if old_call not in session:
        raise RuntimeError("audio session recovery callback was not found")
    session = session.replace(old_call, new_call)
SESSION.write_text(session, encoding="utf-8")

print("Now Playing, buffered AutoMix, and headphone route recovery applied.")
