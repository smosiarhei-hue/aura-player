import SwiftUI

// MARK: - Synchronized Karaoke Lyrics View (Apple Music Style, 120 FPS ProMotion, Syllable Sweep)

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    @State private var player = ActivePlayerPresentation()
    @State private var settings = SettingsStore.shared

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            Group {
                if isLoading {
                    AuraLoadingState(title: "Загрузка текста…")
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
        .task { await player.observeTimeline() }
    }
}

// MARK: - Synchronized Scrolling Lyrics (120 FPS, Auto-centered, Smooth Spring Scrolling)

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    @State private var player = ActivePlayerPresentation()
    @State private var settings = SettingsStore.shared

    // Sub-millisecond acoustic lead compensation (+0.16s) matching player engine
    private var currentTime: Double {
        max(0, player.progress + settings.lyricsOffset + 0.16)
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
                LazyVStack(spacing: 32) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        Button {
                            Haptics.tap(.medium)
                            player.seek(to: max(0, line.startTime - 0.05))
                        } label: {
                            LyricsLineView(
                                line: line,
                                isActive: idx == activeIndex,
                                currentTime: currentTime,
                                fontSize: max(settings.lyricsFontSize, 28)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(line.text)
                        .accessibilityHint("Перемотать к этой строке")
                        .id(idx)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 180)
                .padding(.bottom, 240)
                .frame(maxWidth: .infinity)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .compositingGroup()
        .task { await player.observeTimeline() }
    }
}

// MARK: - Single Line (120 Hz Smooth Syllable Karaoke Highlight)

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool
    let currentTime: Double
    let fontSize: Double

    private var words: [LyricWord] {
        if let w = line.words, !w.isEmpty {
            return w.enumerated().map { i, item in
                LyricWord(
                    id: "\(line.id)_w\(i)",
                    text: item.text,
                    startTime: item.startTime,
                    duration: max(0.10, item.endTime - item.startTime)
                )
            }
        } else {
            let tokens = line.text.split(separator: " ").map(String.init)
            let duration = max(1.2, (line.endTime ?? (line.startTime + 4.0)) - line.startTime)
            let wordDur = duration / Double(max(1, tokens.count))
            return tokens.enumerated().map { i, token in
                LyricWord(
                    id: "\(line.id)_w\(i)",
                    text: token,
                    startTime: line.startTime + Double(i) * wordDur,
                    duration: wordDur
                )
            }
        }
    }

    var body: some View {
        if isActive {
            LyricsFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(words) { word in
                    KineticWordView(
                        word: word,
                        currentTime: currentTime,
                        fontSize: fontSize
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(1.02, anchor: .leading)
            .animation(.spring(response: 0.40, dampingFraction: 0.82), value: isActive)
        } else {
            Text(line.text)
                .font(.system(size: fontSize * 0.84, weight: .semibold, design: .default))
                .foregroundStyle(Color.white.opacity(0.38))
                .multilineTextAlignment(.leading)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(0.96, anchor: .leading)
                .animation(.spring(response: 0.40, dampingFraction: 0.82), value: isActive)
        }
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
                    Text(title).font(AG.display(.title2, .heavy))
                    if let artist = lyrics.artist, !artist.isEmpty {
                        Text(artist).font(AG.text(.callout, .semibold)).foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 6)
                }
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: settings.lyricsFontSize * 0.82, weight: .medium))
                        .foregroundStyle(AG.ink.opacity(0.88))
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
    @State private var player = ActivePlayerPresentation()
    @State private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(AG.inkFaint)

            Text("Текст песни не найден")
                .font(AG.display(.headline, .bold))
                .foregroundStyle(AG.ink)

            if let staticText = player.displayTrack?.lyricsText, !staticText.isEmpty {
                ScrollView {
                    Text(staticText)
                        .font(AG.text(.subheadline))
                        .foregroundStyle(AG.inkMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 28)
                }
            } else {
                Text("Для этого трека пока нет синхронизированного караоке.")
                    .font(AG.text(.footnote))
                    .foregroundStyle(AG.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(28)
    }
}
