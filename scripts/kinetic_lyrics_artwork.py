from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


screen = SCREEN.read_text(encoding="utf-8")

original_artwork = '''                        if settings.fullScreenArtworkEnabled {
                            Color.clear
                                .frame(height: max(geo.size.height * 0.38, coverSide * 0.82))
                                .padding(.top, 4)
                        } else {
                            animatedCover(side: coverSide)
                                .padding(.top, 18)
                        }
'''
kinetic_artwork = '''                        if settings.showTeleprompterInPlayer,
                           let lines = activeLyricsLines {
                            KineticLyricsArtwork(
                                phrase: lines.current,
                                beat: beat,
                                isPlaying: player.isPlaying,
                                reduceMotion: reduceMotion
                            ) {
                                showLyrics = true
                            }
                            .id(lines.current)
                            .frame(
                                width: settings.fullScreenArtworkEnabled ? max(geo.size.width - 44, 1) : coverSide,
                                height: settings.fullScreenArtworkEnabled ? max(geo.size.height * 0.30, 240) : coverSide
                            )
                            .padding(.top, settings.fullScreenArtworkEnabled ? 4 : 18)
                        } else if settings.fullScreenArtworkEnabled {
                            Color.clear
                                .frame(height: max(geo.size.height * 0.38, coverSide * 0.82))
                                .padding(.top, 4)
                        } else {
                            animatedCover(side: coverSide)
                                .padding(.top, 18)
                        }
'''
screen = replace_required(
    screen,
    original_artwork,
    kinetic_artwork,
    "kinetic lyrics artwork placement",
)

screen = replace_required(
    screen,
    '''                        if settings.showTeleprompterInPlayer {
                            inlineLyrics
                                .padding(.top, 14)
                        }
''',
    '''                        if settings.showTeleprompterInPlayer && activeLyricsLines == nil {
                            inlineLyrics
                                .padding(.top, 14)
                        }
''',
    "remove duplicate inline lyrics",
)

SCREEN.write_text(screen, encoding="utf-8")
print("Beat-reactive kinetic lyrics artwork integrated into the player.")
