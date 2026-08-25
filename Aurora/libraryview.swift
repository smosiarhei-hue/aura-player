import SwiftUI

struct LibraryView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var isScanning = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Все", recent = "Недавние", favorites = "Избранное"
        var id: String { rawValue }
    }

    var filtered: [Track] {
        var list = library.tracks
        switch filter {
        case .all: break
        case .recent: list = Array(list.sorted { $0.addedAt > $1.addedAt }.prefix(30))
        case .favorites: list = list.filter(\.isFavorite)
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    emptyState
                } else {
                    trackList
                }
            }
            .navigationTitle("Медиатека")
            .searchable(text: $searchText, prompt: "Трек, исполнитель")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isScanning = true; Task { await library.rescan(); isScanning = false } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(isScanning)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Медиатека пуста")
                .font(.title3.weight(.semibold))
            Text("Импортируйте файлы во вкладке «Обзор» или найдите треки в каталоге Jamendo — миллионы свободных треков.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Track list

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { f in
                            Button { withAnimation(.spring(response: 0.25)) { filter = f } } label: {
                                Text(f.rawValue)
                                    .font(.caption.weight(filter == f ? .semibold : .regular))
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(filter == f
                                            ? AnyShapeStyle(SettingsStore.shared.accentGradient)
                                            : AnyShapeStyle(.primary.opacity(0.06)))
                                    )
                                    .foregroundStyle(filter == f ? .white : .secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }

                ForEach(filtered) { track in
                    trackRow(track)
                }
            }
            .padding(.bottom, 80)
        }
    }

    // MARK: - Row

    private func trackRow(_ track: Track) -> some View {
        Button { player.play(track, newQueue: filtered) } label: {
            HStack(spacing: 14) {
                SmallArtwork(palette: track.palette, size: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if player.currentTrack?.id == track.id {
                            Image(systemName: player.isPlaying ? "waveform" : "pause")
                                .font(.caption2).foregroundStyle(SettingsStore.shared.accentColor)
                        }
                        Text(track.title)
                            .font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                        if track.isFavorite {
                            Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                        }
                    }
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(player.formatted(track.duration))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { library.toggleFavorite(track.id) } label: {
                Label(track.isFavorite ? "Убрать из избранного" : "В избранное",
                      systemImage: track.isFavorite ? "heart.slash" : "heart")
            }
            Divider()
            Button(role: .destructive) { library.delete(track) } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }
}
