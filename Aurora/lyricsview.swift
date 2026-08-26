import SwiftUI

// MARK: - Synchronized Karaoke Lyrics View (line highlight + progressive fill + auto-scroll)

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Загрузка текста…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics, !lyrics.lines.isEmpty {
                if lyrics.isSynchronized {
                    SyncedLyrics(lyrics: lyrics)
                } else {
                    StaticLyricsList(lyrics: lyrics)
                }
            } else {
                EmptyLyricsState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Synchronized Scrolling Lyrics

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared

    private var currentTime: Double { player.progress + settings.lyricsOffset }

    private var activeIndex: Int? {
        let t = currentTime
        return lyrics.lines.firstIndex { line in
            t >= line.startTime && t < (line.endTime ?? .greatestFiniteMagnitude)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        LyricsLineView(
                            line: line,
                            isActive: idx == activeIndex,
                            currentTime: currentTime,
                            fontSize: settings.lyricsFontSize
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.seek(to: line.startTime)
                        }
                        .id(idx)
                    }
                }
                .padding(.vertical, 150)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeIndex) { newIndex in
                guard let newIndex else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Single Line (focused lyrics: big active line, dim surrounding)

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool
    let currentTime: Double
    let fontSize: Double

    private var lineFont: Font {
        .system(size: isActive ? fontSize : fontSize * 0.72,
                weight: isActive ? .heavy : .semibold)
    }

    var body: some View {
        Group {
            if let words = line.words, !words.isEmpty {
                Text(wordAttributed(words: words))
                    .font(lineFont)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                Text(line.text)
                    .font(lineFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .opacity(isActive ? 1.0 : 0.28)
        .blur(radius: isActive ? 0 : 1)
        .shadow(color: isActive ? .white.opacity(0.35) : .clear, radius: isActive ? 14 : 0)
        .scaleEffect(isActive ? 1.0 : 0.96)
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }

    private func wordAttributed(words: [LyricsWord]) -> AttributedString {
        var result = AttributedString()
        for w in words {
            if currentTime < w.startTime {
                var piece = AttributedString(w.text)
                piece.foregroundColor = .white.opacity(0.45)
                result += piece
            } else if currentTime < w.endTime {
                // active word — smooth left-to-right fill
                let span = max(w.endTime - w.startTime, 0.001)
                let fraction = min(1.0, (currentTime - w.startTime) / span)
                let chars = Array(w.text)
                let split = Int(Double(chars.count) * fraction)
                let sung = String(chars.prefix(split))
                let unsung = String(chars.suffix(max(0, chars.count - split)))
                if !sung.isEmpty {
                    var s = AttributedString(sung)
                    s.foregroundColor = .white.opacity(1.0)
                    result += s
                }
                if !unsung.isEmpty {
                    var u = AttributedString(unsung)
                    u.foregroundColor = .white.opacity(0.45)
                    result += u
                }
            } else {
                var piece = AttributedString(w.text)
                piece.foregroundColor = .white.opacity(1.0)
                result += piece
            }
        }
        return result
    }
}

// MARK: - Static (unsynced) Lyrics List

private struct StaticLyricsList: View {
    let lyrics: Lyrics
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let title = lyrics.title, !title.isEmpty {
                    Text(title).font(.title.weight(.heavy))
                    if let artist = lyrics.artist, !artist.isEmpty {
                        Text(artist).font(.title3).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 6)
                }
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: settings.lyricsFontSize * 0.8))
                        .lineSpacing(6)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Empty / Not Found State

private struct EmptyLyricsState: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)

            Text("Синхронизированный текст не найден")
                .font(.headline)
                .foregroundStyle(.primary)

            if let staticText = player.currentTrack?.lyricsText, !staticText.isEmpty {
                Text(staticText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(6)
                    .padding(.horizontal, 28)
            } else {
                Text("Для этого трека нет текста в LRCLIB и в метаданных. Попробуйте другой трек.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(28)
    }
}
