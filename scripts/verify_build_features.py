from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Aurora/playercore.swift").read_text(encoding="utf-8")
SESSION = (ROOT / "Aurora/playbackaudiosession.swift").read_text(encoding="utf-8")
SCREEN = (ROOT / "Aurora/PlayerScreenV2.swift").read_text(encoding="utf-8")
APP = (ROOT / "Aurora/auroraapp.swift").read_text(encoding="utf-8")
BOTTOM = (ROOT / "Aurora/PlayerBottomGlassBar.swift").read_text(encoding="utf-8")
CHROME = (ROOT / "Aurora/playerchrome.swift").read_text(encoding="utf-8")
LYRICS = (ROOT / "Aurora/lyricsview.swift").read_text(encoding="utf-8")
KINETIC = (ROOT / "Aurora/KineticLyricsArtwork.swift").read_text(encoding="utf-8")
STREAM = (ROOT / "Aurora/streambeat.swift").read_text(encoding="utf-8")
FULLSCREEN = (ROOT / "Aurora/fullscreenartwork.swift").read_text(encoding="utf-8")
THEME = (ROOT / "Aurora/theme.swift").read_text(encoding="utf-8")
MODELS = (ROOT / "Aurora/models.swift").read_text(encoding="utf-8")
YANDEX = (ROOT / "Aurora/yandexmusicservice.swift").read_text(encoding="utf-8")
AI = (ROOT / "Aurora/ai_config.swift").read_text(encoding="utf-8")
checks = {
"Observation": (PLAYER, "@Observable\n@MainActor\nfinal class PlayerCore"),
"artwork": (PLAYER, "nonisolated private static func nowPlayingArtwork"),
"media session": (PLAYER, "systemNowPlayingSession.becomeActiveIfPossible"),
"single-flight seek": (PLAYER, "cancelPendingSeeks()"),
"AutoMix": (PLAYER, "private func completeStreamingTransition()"),
"route recovery": (PLAYER, "recoverAudioPipelineAfterRouteChange"),
"Swift 6 notification isolation": (PLAYER, "MainActor.assumeIsolated"),
"efficient 30 Hz progress": (PLAYER, "CMTime(seconds: 1.0 / 30.0"),
"one-shot sleep timer": (PLAYER, "Timer(timeInterval: delay, repeats: false)"),
"tap seeking": (SCREEN, "SpatialTapGesture().onEnded"),
"edge artwork paging": (SCREEN, "completeArtworkPage(forward:"),
"fixed bottom controls": (SCREEN, "PlayerBottomGlassBar("),
"native glass container": (BOTTOM, "GlassEffectContainer"),
"native glass buttons": (BOTTOM, ".buttonStyle(.glass)"),
"prominent glass play": (BOTTOM, ".buttonStyle(.glassProminent)"),
"AutoMix gear menu": (BOTTOM, "Выключить AutoMix"),
"mini-player upward expansion": (APP, "value.translation.height < -20"),
"vintage emerald placement": (SCREEN, "highlightedWordCount: activeLyricsHighlightedWordCount"),
"word synchronized lyrics": (SCREEN, "activeLyricsHighlightedWordCount"),
"vintage serif": (KINETIC, 'font(.custom("Baskerville-Bold"'),
"emerald karaoke split": (KINETIC, "highlightedWordCount"),
"ghost lyric layer": (KINETIC, "emeraldDeep.opacity(0.16)"),
"lightweight lyric glow": (KINETIC, "radius: 16"),
"static efficient artwork": (SCREEN, "private func animatedCover(side: CGFloat)"),
"video resolution cap": (FULLSCREEN, "preferredMaximumResolution"),
"transparent video surface": (FULLSCREEN, "backgroundColor = .clear"),
"immersive artwork": (SCREEN, "fullScreenMediaBackground"),
"undimmed visual media": (SCREEN, "resolvedVideoShotURL ?? track?.videoShotURL"),
"video shot model": (MODELS, "videoShotURL"),
"Yandex video shot": (YANDEX, "backgroundVideoUri"),
"visual media enrichment": (YANDEX, "func loadVisualMedia(for track: Track)"),
"looping video surface": (FULLSCREEN, "AVPlayerLooper"),
"reference queue style": (CHROME, "private var playbackModes"),
"EQ UI": (CHROME, "struct PlayerEQSheetView"),
"C stream tap": (STREAM, "takeRetainedValue()"),
"AI": (AI, "nonisolated enum SonivoAIConfig"),
}
missing = [name for name, (content, marker) in checks.items() if marker not in content]
for path in (ROOT / "Aurora/SonivoStreamEQ.h", ROOT / "Aurora/SonivoStreamEQ.c"):
    if not path.exists(): missing.append(path.name)
if "Artwork intentionally omitted" in PLAYER: missing.append("artwork disabled")
if 'Text("КАРАОКЕ")' in SCREEN: missing.append("legacy karaoke label still present")
if "TimelineView" in KINETIC: missing.append("continuous lyric display timer still present")
if "Color.black" in KINETIC: missing.append("lyric background overlay still present")
if "RadialGradient" in KINETIC: missing.append("lyric video tint still present")
if "compositingGroup" in APP: missing.append("mini-player offscreen compositing still present")
if missing:
    print("Build feature verification failed:")
    for name in missing: print("- " + name)
    raise SystemExit(1)
print("Build feature verification passed.")
for name in checks: print("- " + name + ": OK")
