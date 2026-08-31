from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHROME = ROOT / "Aurora" / "playerchrome.swift"
ARTISTS = ROOT / "Aurora" / "artistviews.swift"

chrome = CHROME.read_text(encoding="utf-8")
start_marker = "// MARK: - Queue"
end_marker = "// MARK: - Equalizer"
if start_marker not in chrome or end_marker not in chrome:
    raise RuntimeError("queue style: section markers were not found")
start = chrome.index(start_marker)
end = chrome.index(end_marker)
queue_section = r'''// MARK: - Queue

struct QueueSheetView: View {
    @State private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    private var upcoming: [Track] {
        player.queue.filter { $0.id != player.currentTrack?.id }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                queueBackdrop
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let current = player.currentTrack {
                            currentHeader(current)
                                .padding(.bottom, 18)
                        }

                        playbackModes
                            .padding(.bottom, 30)

                        Text("Продолжить воспроизведение")
                            .font(.system(size: 29, weight: .bold, design: .default))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .padding(.bottom, 10)

                        if upcoming.isEmpty {
                            ContentUnavailableView(
                                "Очередь пуста",
                                systemImage: "music.note.list",
                                description: Text("Выберите музыку из каталога или медиатеки.")
                            )
                            .foregroundStyle(.white)
                        } else {
                            ForEach(upcoming) { track in
                                Button { player.play(track) } label: {
                                    queueRow(track)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Удалить из очереди", systemImage: "trash", role: .destructive) {
                                        player.removeFromQueue(track)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .colorScheme(.dark)
    }

    private func currentHeader(_ track: Track) -> some View {
        HStack(spacing: 14) {
            SmallArtwork(track: track, size: 82)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 23, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(track.artist)
                    .font(.system(size: 18, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22)
    }

    private var playbackModes: some View {
        HStack(spacing: 12) {
            modeButton("shuffle", active: player.shuffle) { player.shuffle.toggle() }
            modeButton("repeat", active: player.repeatMode == .all) {
                player.repeatMode = player.repeatMode == .all ? .off : .all
            }
            modeButton("infinity", active: player.repeatMode == .one) {
                player.repeatMode = player.repeatMode == .one ? .off : .one
            }
            modeButton("waveform.path.ecg", active: player.transitionMode == .automix) {
                player.transitionMode = player.transitionMode == .automix ? .off : .automix
            }
        }
        .padding(.horizontal, 22)
    }

    private func modeButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(active ? .black.opacity(0.78) : .white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(active ? .white.opacity(0.82) : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func queueRow(_ track: Track) -> some View {
        HStack(spacing: 14) {
            SmallArtwork(track: track, size: 58)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 21, weight: .regular, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 16, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var queueBackdrop: some View {
        ZStack {
            Color.black
            if let track = player.currentTrack,
               let cover = track.coverURL,
               let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill().blur(radius: 70, opaque: true).opacity(0.30)
                    } else { Color.clear }
                }
            }
            LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.82)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

'''
chrome = chrome[:start] + queue_section + chrome[end:]
CHROME.write_text(chrome, encoding="utf-8")

artists = ARTISTS.read_text(encoding="utf-8")
replacements = [
    ('.frame(height: 320)', '.frame(height: 500)'),
    ('.font(AG.display(32, .heavy))', '.font(.system(size: 46, weight: .bold, design: .default))'),
    ('SonivoHeader(title: "Популярные", accent: "треки").padding(.horizontal, 16)', 'Text("Популярные песни")\n                        .font(.system(size: 30, weight: .bold, design: .default))\n                        .foregroundStyle(.white)\n                        .padding(.horizontal, 18)'),
    ('SonivoHeader(title: "Альбомы", accent: "и синглы").padding(.horizontal, 16)', 'Text("Альбомы и синглы")\n                        .font(.system(size: 30, weight: .bold, design: .default))\n                        .foregroundStyle(.white)\n                        .padding(.horizontal, 18)'),
    ('.font(AG.display(25, .heavy))', '.font(.system(size: 29, weight: .bold, design: .default))'),
]
for old, new in replacements:
    if old not in artists and new not in artists:
        raise RuntimeError("artist style anchor was not found: " + old)
    artists = artists.replace(old, new)
ARTISTS.write_text(artists, encoding="utf-8")
print("Cinematic karaoke, queue, and artist typography applied.")
