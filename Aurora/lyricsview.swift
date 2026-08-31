import SwiftUI

// MARK: - Synchronized Karaoke Lyrics View (Apple Music Style, 120 FPS, Progressive Vocal Glow)

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(AG.amber)
                        .scaleEffect(1.2)
                    Text("Загрузка текста…")
                        .font(AG.text(14, .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                }
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

// MARK: - Synchronized Scrolling Lyrics (120 FPS, Auto-centered, Edge Fade Mask)

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    // Built-in acoustic lead compensation (-0.12s) + user offset for vocal precision
    private var currentTime: Double {
        max(0, player.progress + settings.lyricsOffset - 0.12)
    }

    private var activeIndex: Int? {
        let t = currentTime
        return lyrics.lines.lastIndex { line in
            t >= line.startTime && t < (line.endTime ?? (line.startTime + 6.0))
        } ?? lyrics.lines.firstIndex { $0.startTime > t }.map { max(0, $0 - 1) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 22) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        LyricsLineView(
                            line: line,
                            isActive: idx == activeIndex,
                            currentTime: currentTime,
                            fontSize: max(settings.lyricsFontSize, 24)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            player.seek(to: max(0, line.startTime - 0.05))
                        }
                        .id(idx)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 180)
                .padding(.bottom, 240)
                .frame(maxWidth: .infinity)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.10),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .compositingGroup()
    }
}

// MARK: - Single Line (Apple Music Sing: progressive vocal karaoke highlight)

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool
    let currentTime: Double
    let fontSize: Double

    private var lineFont: Font {
        .system(size: isActive ? fontSize : fontSize * 0.82,
                weight: isActive ? .bold : .semibold,
                design: .rounded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let words = line.words, !words.isEmpty, isActive {
                // Word-level karaoke progressive fill
                Text(wordAttributed(words: words))
                    .font(lineFont)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(6)
            } else {
                Text(line.text)
                    .font(lineFont)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isActive ? 1.0 : 0.32)
        .blur(radius: isActive ? 0 : 0.4)
        .scaleEffect(isActive ? 1.0 : 0.96, anchor: .leading)
        .shadow(color: isActive ? Color.white.opacity(0.35) : .clear, radius: isActive ? 12 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isActive)
    }

    private func wordAttributed(words: [LyricsWord]) -> AttributedString {
        var result = AttributedString()
        for w in words {
            if currentTime < w.startTime {
                // Unsung upcoming word
                var piece = AttributedString(w.text)
                piece.foregroundColor = .white.opacity(0.35)
                result += piece
            } else if currentTime < w.endTime {
                // Active sung word: progressive character glow
                let span = max(w.endTime - w.startTime, 0.05)
                let fraction = min(1.0, max(0.0, (currentTime - w.startTime) / span))
                let chars = Array(w.text)
                let split = Int(Double(chars.count) * fraction)
                let sung = String(chars.prefix(split))
                let unsung = String(chars.suffix(max(0, chars.count - split)))

                if !sung.isEmpty {
                    var s = AttributedString(sung)
                    s.foregroundColor = .white
                    result += s
                }
                if !unsung.isEmpty {
                    var u = AttributedString(unsung)
                    u.foregroundColor = .white.opacity(0.35)
                    result += u
                }
            } else {
                // Completed sung word
                var piece = AttributedString(w.text)
                piece.foregroundColor = .white
                result += piece
            }
        }
        return result
    }
}

// MARK: - Static (unsynced) Lyrics List

private struct StaticLyricsList: View {
    let lyrics: Lyrics
    @State private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let title = lyrics.title, !title.isEmpty {
                    Text(title).font(AG.display(22, .heavy))
                    if let artist = lyrics.artist, !artist.isEmpty {
                        Text(artist).font(AG.text(16, .semibold)).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 6)
                }
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(AG.text(settings.lyricsFontSize * 0.82, .medium))
                        .foregroundStyle(.white.opacity(0.88))
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
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.40))

            Text("Текст песни не найден")
                .font(AG.display(18, .bold))
                .foregroundStyle(.white)

            if let staticText = player.currentTrack?.lyricsText, !staticText.isEmpty {
                ScrollView {
                    Text(staticText)
                        .font(AG.text(14, .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 28)
                }
            } else {
                Text("Для этого трека пока нет синхронизированного караоке.")
                    .font(AG.text(13, .regular))
                    .foregroundStyle(.white.opacity(0.50))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(28)
    }
}
