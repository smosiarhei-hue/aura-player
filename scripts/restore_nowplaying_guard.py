from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
text = PLAYER.read_text(encoding="utf-8")

# restorePlaybackState() runs during PlayerCore init at cold start. Publishing
# Now Playing info there makes MediaPlayer serialize the artwork on its
# background accessQueue within the first second of launch. Now Playing is
# only needed once playback actually starts, so skip the publish entirely.
old = '''        streamDuration = track.duration
        isPlaying = false
        isUsingStreamPlayer = false
        updateNowPlayingInfo()
    }

    private func persistPlaybackState'''
new = '''        streamDuration = track.duration
        isPlaying = false
        isUsingStreamPlayer = false
        // Now Playing info is intentionally not published at launch; it is
        // published when the user starts playback.
    }

    private func persistPlaybackState'''
if new not in text:
    if old not in text:
        print("[patch-skip] " + str("restorePlaybackState anchor was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(old, new, 1)

PLAYER.write_text(text, encoding="utf-8")
print("Launch-time Now Playing publish disabled.")
