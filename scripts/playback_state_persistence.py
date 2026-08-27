from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
text = PLAYER.read_text()

state_anchor = '''    private let defaults = UserDefaults.standard
'''
state_block = '''    private let defaults = UserDefaults.standard
    private static let playbackStateKey = "player.lastPlaybackState.v1"
    private var lastPlaybackStateWrite = Date.distantPast

    private struct PlaybackSnapshot: Codable {
        let track: Track
        let position: Double
    }
'''
if state_block not in text:
    if state_anchor not in text:
        raise RuntimeError("Player defaults anchor was not found")
    text = text.replace(state_anchor, state_block, 1)

init_old = '''        loadSettings()
        setupRemoteCommandCenter()
    }'''
init_new = '''        loadSettings()
        setupRemoteCommandCenter()
        restorePlaybackState()
    }'''
if init_new not in text:
    if init_old not in text:
        raise RuntimeError("Player initializer anchor was not found")
    text = text.replace(init_old, init_new, 1)

controls_anchor = '''    // MARK: - Playback Controls
'''
persistence_methods = '''    // MARK: - Playback State Restoration

    private func restorePlaybackState() {
        guard let data = defaults.data(forKey: Self.playbackStateKey),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else {
            return
        }

        let track = snapshot.track
        if !track.isStream && !FileManager.default.fileExists(atPath: track.url.path) {
            defaults.removeObject(forKey: Self.playbackStateKey)
            return
        }

        let upperBound = track.duration > 0 ? track.duration : snapshot.position
        let restoredPosition = max(0, min(snapshot.position, upperBound))
        currentTrack = track
        queue = [track]
        progress = restoredPosition
        pausedProgress = restoredPosition
        anchorOffset = restoredPosition
        streamDuration = track.duration
        isPlaying = false
        isUsingStreamPlayer = false
        updateNowPlayingInfo()
    }

    private func persistPlaybackState(force: Bool = false) {
        guard let track = currentTrack else {
            defaults.removeObject(forKey: Self.playbackStateKey)
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastPlaybackStateWrite) >= 1 else { return }
        lastPlaybackStateWrite = now

        let currentPosition: Double
        if isUsingStreamPlayer {
            currentPosition = progress
        } else if isPlaying {
            currentPosition = liveProgress()
        } else {
            currentPosition = pausedProgress
        }

        let snapshot = PlaybackSnapshot(track: track, position: max(0, currentPosition))
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.playbackStateKey)
        }
    }

    // MARK: - Playback Controls
'''
if persistence_methods not in text:
    if controls_anchor not in text:
        raise RuntimeError("Playback controls anchor was not found")
    text = text.replace(controls_anchor, persistence_methods, 1)

stream_old = '''                    self.scheduleTransitionIfNeeded()
                    self.updateNowPlayingInfo()
'''
stream_new = '''                    self.scheduleTransitionIfNeeded()
                    self.updateNowPlayingInfo()
                    self.persistPlaybackState()
'''
if stream_new not in text:
    if stream_old not in text:
        raise RuntimeError("Streaming progress anchor was not found")
    text = text.replace(stream_old, stream_new, 1)

play_old = '''        cancelTransition()
        start(at: 0)
    }

    func pause()'''
play_new = '''        cancelTransition()
        start(at: 0)
        persistPlaybackState(force: true)
    }

    func pause()'''
if play_new not in text:
    if play_old not in text:
        raise RuntimeError("Play persistence anchor was not found")
    text = text.replace(play_old, play_new, 1)

pause_old = '''        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume()'''
pause_new = '''        isPlaying = false
        updateNowPlayingInfo()
        persistPlaybackState(force: true)
    }

    func resume()'''
if pause_new not in text:
    if pause_old not in text:
        raise RuntimeError("Pause persistence anchor was not found")
    text = text.replace(pause_old, pause_new, 1)

seek_old = '''        }
        updateNowPlayingInfo()
    }

    func stopAndClear()'''
seek_new = '''        }
        updateNowPlayingInfo()
        persistPlaybackState(force: true)
    }

    func stopAndClear()'''
if seek_new not in text:
    if seek_old not in text:
        raise RuntimeError("Seek persistence anchor was not found")
    text = text.replace(seek_old, seek_new, 1)

clear_old = '''        SpectrumAnalyzer.shared.reset()
        updateNowPlayingInfo()
    }'''
clear_new = '''        SpectrumAnalyzer.shared.reset()
        defaults.removeObject(forKey: Self.playbackStateKey)
        updateNowPlayingInfo()
    }'''
if clear_new not in text:
    if clear_old not in text:
        raise RuntimeError("Clear persistence anchor was not found")
    text = text.replace(clear_old, clear_new, 1)

tick_old = '''        progress = liveProgress()
        scheduleTransitionIfNeeded()
    }'''
tick_new = '''        progress = liveProgress()
        scheduleTransitionIfNeeded()
        persistPlaybackState()
    }'''
if tick_new not in text:
    if tick_old not in text:
        raise RuntimeError("Local progress persistence anchor was not found")
    text = text.replace(tick_old, tick_new, 1)

PLAYER.write_text(text)
