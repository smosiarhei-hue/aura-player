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
                LazyVStack(spacing: 18) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        LyricsLineView(
                            line: line,
                            isActive: idx == activeIndex,
                            progress: progress(for: line),
                            highlight: settings.lyricsHighlightColor,
                            fontSize: settings.lyricsFontSize
                        )
                        .id(idx)
                    }
                }
                .padding(.vertical, 240)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeIndex) { newIndex in
                guard let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func progress(for line: LyricsLine) -> Double {
        let t = currentTime
        if let words = line.words, !words.isEmpty {
            if t < (words.first?.startTime ?? 0) { return 0 }
            for (i, w) in words.enumerated() {
                if t >= w.startTime && t < w.endTime {
                    let wordProgress = (t - w.startTime) / max(w.endTime - w.startTime, 0.001)
                    return min(1, (Double(i) + wordProgress) / Double(words.count))
                }
            }
            return 1
        }
        guard let end = line.endTime, end > line.startTime else { return 0 }
        return min(max((t - line.startTime) / (end - line.startTime), 0), 1)
    }
}

// MARK: - Single Line with Karaoke Fill

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool
    let progress: Double
    let highlight: Color
    let fontSize: Double

    var body: some View {
        Text(line.text)
            .font(.system(size: fontSize, weight: isActive ? .bold : .regular))
            .foregroundStyle(isActive ? highlight.opacity(0.45) : Color.secondary.opacity(0.55))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .overlay {
                if isActive {
                    Text(line.text)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle()
                                    .frame(width: max(0, geo.size.width * progress))
                            }
                        }
                }
            }
            .scaleEffect(isActive ? 1.0 : 0.92)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
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
