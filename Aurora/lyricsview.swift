import SwiftUI
import AVFoundation

// MARK: - Synchronized Karaoke Lyrics View (Apple Music Style, 120 FPS ProMotion, Syllable Sweep)

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    var player: ActivePlayerPresentation = .shared
    @State private var settings = SettingsStore.shared

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if isLoading {
                    AuraLoadingState(title: "Загрузка текста…")
                } else if let lyrics, !lyrics.lines.isEmpty {
                    if lyrics.isSynchronized {
                        SyncedLyrics(lyrics: lyrics, player: player)
                    } else {
                        StaticLyricsList(lyrics: lyrics)
                    }
                } else {
                    EmptyLyricsState(player: player)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Real-time Apple Music Sing style vocal isolation slider overlay
            VocalIsolationControlView()
                .padding(.trailing, 22)
                .padding(.bottom, 38)
        }
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = player.displayTrack.flatMap({ LibraryStore.cachedArtworkImage(for: $0) }) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 24)
                        .scaleEffect(1.15)
                        .opacity(0.38)
                        .clipped()
                        .ignoresSafeArea()
                }
                Color.black.opacity(0.45).ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task { await player.observeTimeline() }
    }
}

// MARK: - Synchronized Scrolling Lyrics (Auto-centered, Smooth Glide Scrolling)

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    let player: ActivePlayerPresentation
    @State private var settings = SettingsStore.shared
    @State private var userScrolledUntil: Date = .distantPast

    private var isUserInteracting: Bool {
        Date() < userScrolledUntil
    }

    private var activeIndex: Int? {
        guard lyrics.isSynchronized, !lyrics.lines.isEmpty else { return nil }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let currentTime = max(0, player.progress - latency + settings.lyricsOffset)
        if let first = lyrics.lines.first, currentTime < first.startTime {
            return nil
        }
        for (idx, line) in lyrics.lines.enumerated() {
            let nextStart = (idx + 1 < lyrics.lines.count) ? lyrics.lines[idx + 1].startTime : (line.startTime + 20.0)
            if currentTime >= line.startTime && currentTime < nextStart {
                return idx
            }
        }
        return lyrics.lines.count - 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 28) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        Button {
                            Haptics.tap(.medium)
                            userScrolledUntil = .distantPast
                            if lyrics.isSynchronized {
                                player.seek(to: max(0, line.startTime))
                                if !player.isPlaying {
                                    player.resume()
                                }
                            }
                            withAnimation(.easeInOut(duration: 0.42)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        } label: {
                            LyricsLineView(
                                line: line,
                                isActive: idx == activeIndex
                            )
                        }
                        .buttonStyle(LyricsLineButtonStyle())
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
                .padding(.horizontal, 24)
                .padding(.vertical, 240)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        userScrolledUntil = Date().addingTimeInterval(4.5)
                    }
            )
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
            .overlay(alignment: .bottomTrailing) {
                if isUserInteracting, let activeIndex {
                    Button {
                        Haptics.tap(.light)
                        userScrolledUntil = .distantPast
                        withAnimation(.easeInOut(duration: 0.42)) {
                            proxy.scrollTo(activeIndex, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 11, weight: .bold))
                            Text("К текущей")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.70), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.95))
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex, !isUserInteracting else { return }
                withAnimation(.easeInOut(duration: 0.42)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                if let activeIndex {
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Single Line (Large Bold Centered Typography — Matching Reference)

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool

    var body: some View {
        Text(line.text)
            .font(.system(size: 32, weight: .heavy, design: .default))
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.35))
            .shadow(color: isActive ? Color.black.opacity(0.40) : Color.clear, radius: 4, y: 1.5)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .minimumScaleFactor(0.80)
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.32), value: isActive)
    }
}

private struct LyricsLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Static (unsynced) Lyrics List

private struct StaticLyricsList: View {
    let lyrics: Lyrics
    @State private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 22) {
                if let title = lyrics.title, !title.isEmpty {
                    Text(title)
                        .font(AG.display(.title2, .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if let artist = lyrics.artist, !artist.isEmpty {
                        Text(artist)
                            .font(AG.text(.callout, .semibold))
                            .foregroundStyle(.white.opacity(0.70))
                            .multilineTextAlignment(.center)
                    }
                    Divider().overlay(Color.white.opacity(0.2)).padding(.vertical, 6)
                }
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: 26, weight: .bold, design: .default))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .center)
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
            .padding(.horizontal, 24)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Empty / Not Found State

private struct EmptyLyricsState: View {
    var player: ActivePlayerPresentation = .shared
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
