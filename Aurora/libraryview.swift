import SwiftUI

struct LibraryView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @State private var searchText = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Все", recent = "Недавние", favorites = "Избранное"
        var id: String { rawValue }
    }

    var filtered: [Track] {
        var list = library.tracks
        switch filter {
        case .all: break
        case .recent: list = Array(list.sorted { $0.addedAt > $1.addedAt }.prefix(20))
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
                if library.tracks.isEmpty { emptyState } else { list }
            }
            .navigationTitle("Медиатека")
            .searchable(text: $searchText, prompt: "Трек, исполнитель")
            .refreshable { await library.rescan() }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.house")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Здесь появится ваша музыка")
                .font(.headline)
            Text("Импортируйте файлы на вкладке «Импорт» или перетащите их через Finder / приложение «Файлы».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            NavigationLink { ImportView() } label: { Text("Перейти к импорту") }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Track list

    private var list: some View {
        List {
            Section {
                Picker("Фильтр", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(filtered) { track in row(track)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { library.delete(track) } label: { Label("Удалить", systemImage: "trash") }
                    Button { library.toggleFavorite(track.id) } label: {
                        Label(track.isFavorite ? "Убрать" : "В избранное", systemImage: track.isFavorite ? "heart.slash" : "heart")
                    }.tint(.pink)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Row

    private func row(_ track: Track) -> some View {
        Button { player.play(track, newQueue: filtered) } label: {
            HStack(spacing: 12) {
                SmallArtwork(palette: track.palette, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if player.currentTrack?.id == track.id {
                            Image(systemName: player.isPlaying ? "waveform" : "pause")
                                .font(.caption2).foregroundStyle(SettingsStore.shared.accentColor)
                        }
                        Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                        if track.isFavorite {
                            Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.pink)
                        }
                    }
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(player.formatted(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
