from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Aurora/playercore.swift").read_text(encoding="utf-8")
SESSION = (ROOT / "Aurora/playbackaudiosession.swift").read_text(encoding="utf-8")
SCREEN = (ROOT / "Aurora/PlayerScreenV2.swift").read_text(encoding="utf-8")
CHROME = (ROOT / "Aurora/playerchrome.swift").read_text(encoding="utf-8")
LYRICS = (ROOT / "Aurora/lyricsview.swift").read_text(encoding="utf-8")
STREAM = (ROOT / "Aurora/streambeat.swift").read_text(encoding="utf-8")
AI = (ROOT / "Aurora/ai_config.swift").read_text(encoding="utf-8")
checks = {
"Observation": (PLAYER, "@Observable\n@MainActor\nfinal class PlayerCore"),
"artwork": (PLAYER, "nonisolated private static func nowPlayingArtwork"),
"media session": (PLAYER, "systemNowPlayingSession.isActive = true"),
"single-flight seek": (PLAYER, "cancelPendingSeeks()"),
"AutoMix": (PLAYER, "private func completeStreamingTransition()"),
"stream EQ state": (PLAYER, "StreamBeatTap.shared.updateEQ"),
"route recovery": (PLAYER, "recoverAudioPipelineAfterRouteChange"),
"Now Playing candidate": (SESSION, "setIsNowPlayingCandidate(true)"),
"scrubber": (SCREEN, "onEditingChanged: { editing in"),
"EQ UI": (CHROME, "struct PlayerEQSheetView"),
"calm lyrics": (LYRICS, "private struct CalmSyncedLyrics"),
"C stream tap": (STREAM, "SonivoCreateStreamEQTap"),
"AI": (AI, "nonisolated enum SonivoAIConfig"),
}
missing = [name for name, (content, marker) in checks.items() if marker not in content]
for path in (ROOT / "Aurora/SonivoStreamEQ.h", ROOT / "Aurora/SonivoStreamEQ.c"):
    if not path.exists(): missing.append(path.name)
if "Artwork intentionally omitted" in PLAYER: missing.append("artwork disabled")
if missing:
    print("Build feature verification failed:")
    for name in missing: print("- " + name)
    raise SystemExit(1)
print("Build feature verification passed.")
for name in checks: print("- " + name + ": OK")
