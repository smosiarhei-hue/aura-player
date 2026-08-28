from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Aurora" / "playercore.swift").read_text(encoding="utf-8")
SESSION = (ROOT / "Aurora" / "playbackaudiosession.swift").read_text(encoding="utf-8")
SCREEN = (ROOT / "Aurora" / "PlayerScreenV2.swift").read_text(encoding="utf-8")
CHROME = (ROOT / "Aurora" / "playerchrome.swift").read_text(encoding="utf-8")
AI_CONFIG = (ROOT / "Aurora" / "ai_config.swift").read_text(encoding="utf-8")

required_player = {
    "Observation migration": "@Observable\n@MainActor\nfinal class PlayerCore",
    "lazy audio initialization": "Engine starts lazily when playback begins.",
    "playback restoration": "private func restorePlaybackState()",
    "safe Now Playing artwork": "nonisolated private static func nowPlayingArtwork",
    "Now Playing artwork publication": "MPMediaItemPropertyArtwork",
    "system media identity": "MPNowPlayingInfoPropertyExternalContentIdentifier",
    "remote-control registration": "beginReceivingRemoteControlEvents",
    "second streaming deck": "private var streamingMixPlayer = AVPlayer()",
    "streaming AutoMix preparation": "private func prepareStreamingTransition(",
    "streaming AutoMix completion": "private func completeStreamingTransition()",
    "headphone route recovery": "func recoverAudioPipelineAfterRouteChange()",
}

required_other = {
    "route-change callback": (SESSION, "PlayerCore.shared.recoverAudioPipelineAfterRouteChange()"),
    "full-player EQ": (CHROME, "struct PlayerEQSheetView"),
    "track wave": (SCREEN, "private func startTrackWave()"),
    "AI config": (AI_CONFIG, "nonisolated enum SonivoAIConfig"),
}

missing = [name for name, marker in required_player.items() if marker not in PLAYER]
missing += [name for name, (content, marker) in required_other.items() if marker not in content]

if "Artwork intentionally omitted from Now Playing info" in PLAYER:
    missing.append("artwork is still disabled")

if missing:
    print("Build feature verification failed:")
    for name in missing:
        print(f"- {name}")
    raise SystemExit(1)

print("Build feature verification passed.")
for name in required_player:
    print(f"- {name}: OK")
for name in required_other:
    print(f"- {name}: OK")
