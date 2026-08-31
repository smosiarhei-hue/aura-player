import SwiftUI

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Загрузка текста…")
                    .tint(.white)
            } else if let lyrics, !lyrics.lines.isEmpty {
                if lyrics.isSynchronized { CinematicSyncedLyrics(lyrics: lyrics) }
                else { CinematicStaticLyrics(lyrics: lyrics) }
            } else {
                EmptyLyricsState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CinematicSyncedLyrics: View {
    let lyrics: Lyrics
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    private var activeIndex: Int {
        lyrics.lines.lastIndex(where: { $0.startTime <= player.progress + settings.lyricsOffset }) ?? 0
    }

    private var visibleIndices: [Int] {
        guard !lyrics.lines.isEmpty else { return [] }
        let first = max(0, activeIndex - 1)
        let last = min(lyrics.lines.count - 1, activeIndex + 3)
        return Array(first...last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(visibleIndices, id: \.self) { index in
                let distance = index - activeIndex
                let active = distance == 0
                Button { player.seek(to: lyrics.lines[index].startTime) } label: {
                    Text(lyrics.lines[index].text)
                        .font(.system(
                            size: active ? max(34, settings.lyricsFontSize) : max(28, settings.lyricsFontSize * 0.82),
                            weight: active ? .bold : .semibold,
                            design: .default
                        ))
                        .foregroundStyle(.white.opacity(active ? 1 : distance < 0 ? 0.16 : distance == 1 ? 0.32 : 0.13))
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .blur(radius: active ? 0 : distance == 1 ? 0.45 : 2.2)
                        .shadow(color: active ? .black.opacity(0.55) : .clear, radius: 12, y: 5)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 120)
        }
        .padding(.horizontal, 30)
        .padding(.top, 165)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CinematicStaticLyrics: View {
    let lyrics: Lyrics
    @State private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: max(30, settings.lyricsFontSize * 0.86), weight: .bold, design: .default))
                        .foregroundStyle(.white.opacity(0.86))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 165)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
    }
}

private struct EmptyLyricsState: View {
    @State private var player = PlayerCore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Текст песни")
                .font(.system(size: 36, weight: .bold, design: .default))
                .foregroundStyle(.white)
            Text(player.currentTrack?.lyricsText?.isEmpty == false ? player.currentTrack?.lyricsText ?? "" : "Текст песни не найден")
                .font(.system(size: 25, weight: .semibold, design: .default))
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.leading)
                .lineSpacing(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 30)
        .padding(.top, 165)
    }
}
