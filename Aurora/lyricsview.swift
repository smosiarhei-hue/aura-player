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
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = player.displayTrack.flatMap({ LibraryStore.cachedArtworkImage(for: $0) }) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 16)
                        .scaleEffect(1.1)
                        .opacity(0.30)
                        .clipped()
                        .ignoresSafeArea()
                }
                Color.black.opacity(0.55).ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task { await player.observeTimeline() }
    }
}

// MARK: - Synchronized Scrolling Lyrics (120 FPS, Auto-centered, Smooth Spring Scrolling)

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    @State private var player = ActivePlayerPresentation()
    @State private var settings = SettingsStore.shared
    @State private var anchorTimestamp: Double = CACurrentMediaTime()

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            let now = CACurrentMediaTime()
            let dt = player.isPlaying ? max(0.0, min(0.025, now - anchorTimestamp)) : 0.0
            let latency = AVAudioSession.sharedInstance().outputLatency
            let currentTime = max(0, player.progress - latency + settings.lyricsOffset + dt)

            let activeIndex: Int? = {
                if let first = lyrics.lines.first, currentTime < first.startTime {
                    return nil
                }
                return lyrics.lines.lastIndex { line in
                    currentTime >= line.startTime && currentTime < (line.endTime ?? (line.startTime + 5.0))
                }
            }()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 20) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                            Button {
                                Haptics.tap(.medium)
                                player.seek(to: max(0, line.startTime - 0.05))
                            } label: {
                                LyricsLineView(
                                    line: line,
                                    isActive: idx == activeIndex,
                                    currentTime: currentTime,
                                    fontSize: 21
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(line.text)
                            .accessibilityHint("Перемотать к этой строке")
                            .id(idx)
                        }

                        // Source badge placed directly at the end of the text
                        if !lyrics.sourceName.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Источник: \(lyrics.sourceName)")
                                    .font(.system(size: 12, weight: .medium, design: .default))
                            }
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 24)
                            .padding(.bottom, 40)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 90)
                    .padding(.bottom, 120)
                    .frame(maxWidth: .infinity)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.10),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .compositingGroup()
        .onChange(of: player.progress) { _, _ in
            anchorTimestamp = CACurrentMediaTime()
        }
        .task { await player.observeTimeline() }
    }
}

// MARK: - Single Line (120 Hz Smooth Syllable Karaoke Highlight — ZERO Squares)

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool
    let currentTime: Double
    let fontSize: Double

    private var words: [LyricWord] {
        let eff = line.effectiveWords()
        return eff.enumerated().map { i, item in
            LyricWord(
                id: "\(line.id)_w\(i)",
                text: item.text,
                startTime: item.startTime,
                duration: max(0.08, item.endTime - item.startTime)
            )
        }
    }

    var body: some View {
        if isActive {
            if !words.isEmpty {
                // Word-by-word synced line with crisp dynamic vocal sweep (ZERO glow)
                LyricsFlowLayout(spacing: 8, lineSpacing: 8, alignment: .leading) {
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
                    .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.35), radius: 2, y: 1.5)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.70)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(1.02, anchor: .leading)
                    .animation(.spring(response: 0.40, dampingFraction: 0.82), value: isActive)
            }
        } else {
            Text(line.text)
                .font(.system(size: fontSize * 0.84, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.35))
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.70)
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
                    Text(title)
                        .font(AG.display(.title2, .heavy))
                        .foregroundStyle(.white)
                    if let artist = lyrics.artist, !artist.isEmpty {
                        Text(artist)
                            .font(AG.text(.callout, .semibold))
                            .foregroundStyle(.white.opacity(0.70))
                    }
                    Divider().overlay(Color.white.opacity(0.2)).padding(.vertical, 6)
                }
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: settings.lyricsFontSize * 0.82, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(6)
                }
                if !lyrics.sourceName.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Источник: \(lyrics.sourceName)")
                            .font(.system(size: 13, weight: .medium, design: .default))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial.opacity(0.40), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .padding(.top, 24)
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
                .foregroundStyle(Color.white.opacity(0.35))

            Text("Текст песни не найден")
                .font(AG.display(.headline, .bold))
                .foregroundStyle(.white)

            if let staticText = player.displayTrack?.lyricsText, !staticText.isEmpty {
                ScrollView {
                    Text(staticText)
                        .font(AG.text(.subheadline))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 28)
                }
            } else {
                Text("Для этого трека пока нет текста песни.")
                    .font(AG.text(.footnote))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(28)
    }
}
