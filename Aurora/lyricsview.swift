import SwiftUI

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Загрузка текста…")
            } else if let lyrics, !lyrics.lines.isEmpty {
                if lyrics.isSynchronized { CalmSyncedLyrics(lyrics: lyrics) }
                else { StaticLyricsList(lyrics: lyrics) }
            } else {
                EmptyLyricsState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CalmSyncedLyrics: View {
    let lyrics: Lyrics
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    private var activeIndex: Int {
        lyrics.lines.lastIndex(where: { $0.startTime <= player.progress + settings.lyricsOffset }) ?? 0
    }

    private var visibleIndices: [Int] {
        guard !lyrics.lines.isEmpty else { return [] }
        let start = max(0, min(activeIndex - 2, max(0, lyrics.lines.count - 5)))
        return Array(start...min(lyrics.lines.count - 1, start + 4))
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(visibleIndices, id: \.self) { index in
                let active = index == activeIndex
                Button { player.seek(to: lyrics.lines[index].startTime) } label: {
                    Text(lyrics.lines[index].text)
                        .font(.system(size: max(14, settings.lyricsFontSize * 0.62), weight: active ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(active ? 1 : 0.34))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .shadow(color: active ? .white.opacity(0.72) : .clear, radius: 8)
                        .shadow(color: active ? AG.amber.opacity(0.42) : .clear, radius: 18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
    }
}

private struct StaticLyricsList: View {
    let lyrics: Lyrics
    @State private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: max(14, settings.lyricsFontSize * 0.62), design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 90)
        }
    }
}

private struct EmptyLyricsState: View {
    @State private var player = PlayerCore.shared
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.42))
            Text(player.currentTrack?.lyricsText?.isEmpty == false ? player.currentTrack?.lyricsText ?? "" : "Текст песни не найден")
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .lineSpacing(5)
        }
        .padding(28)
    }
}
