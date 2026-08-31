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
                                highlightedWordCount: activeLyricsHighlightedWordCount,
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
screen = replace_required(screen, original_artwork, kinetic_artwork, "vintage emerald lyrics placement")
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
screen = replace_required(
    screen,
    '''    private func loadLyricsPreview() async {
''',
    '''    private var activeLyricsHighlightedWordCount: Int {
        guard let previewLyrics, previewLyrics.isSynchronized, !previewLyrics.lines.isEmpty else { return 0 }
        let time = player.progress + settings.lyricsOffset
        let index = previewLyrics.lines.lastIndex(where: { $0.startTime <= time }) ?? 0
        let line = previewLyrics.lines[index]
        if let timedWords = line.words, !timedWords.isEmpty {
            return timedWords.filter { $0.startTime <= time }.count
        }
        let wordCount = line.text.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount > 0 else { return 0 }
        let nextStart = index + 1 < previewLyrics.lines.count ? previewLyrics.lines[index + 1].startTime : line.startTime + 4
        let end = line.endTime ?? nextStart
        let duration = max(end - line.startTime, 0.25)
        let fraction = min(max((time - line.startTime) / duration, 0), 1)
        return min(wordCount, max(0, Int((fraction * Double(wordCount)).rounded(.up))))
    }

    private func loadLyricsPreview() async {
''',
    "word-level lyric progress",
)
SCREEN.write_text(screen, encoding="utf-8")
print("Vintage emerald word-synchronized lyrics integrated into the player.")
