import SwiftUI

// MARK: - Library View (Apple Music Style)

struct LibraryView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "Все песни", favorites = "Избранное", recent = "Недавние"
        var id: String { rawValue }
    }

    var filteredTracks: [Track] {
        var list = library.tracks
        switch filter {
        case .all: break
        case .favorites: list = list.filter(\.isFavorite)
        case .recent: list = Array(list.sorted { $0.addedAt > $1.addedAt }.prefix(30))
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText) ||
                $0.album.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    emptyStateView
                } else {
                    mainLibraryContent
                }
            }
            .navigationTitle("Медиатека")
            .searchable(text: $searchText, prompt: "Поиск по песням и артистам")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(library.isScanning)
                }
            }
        }
    }

    // MARK: - Main Content

    private var mainLibraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Recently Added Albums / Tracks Grid
                if filter == .all && searchText.isEmpty && library.tracks.count >= 2 {
                    recentlyAddedSection
                }

                // Filter Tabs
                filterChips

                // Songs List
                VStack(spacing: 2) {
                    ForEach(filteredTracks) { track in
                        trackRow(track)
                    }
                }
            }
            .padding(.bottom, 96)
        }
    }

    // MARK: - Recently Added Section (Apple Music Cards)

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Недавно добавленные")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(library.tracks.prefix(8))) { track in
                        Button {
                            player.play(track, newQueue: library.tracks)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                SmallArtwork(track: track, size: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)

                                Text(track.artist)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { f in
                    Button {
                        withAnimation(.spring(response: 0.25)) { filter = f }
                    } label: {
                        Text(f.rawValue)
                            .font(.subheadline.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(filter == f
                                    ? AnyShapeStyle(settings.accentGradient)
                                    : AnyShapeStyle(.primary.opacity(0.06)))
                            )
                            .foregroundStyle(filter == f ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Track Row

    private func trackRow(_ track: Track) -> some View {
        Button {
            player.play(track, newQueue: filteredTracks)
        } label: {
            HStack(spacing: 14) {
                SmallArtwork(track: track, size: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if player.currentTrack?.id == track.id {
                            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                .font(.caption2)
                                .foregroundStyle(settings.accentColor)
                        }
                        Text(track.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        if track.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.pink)
                        }
                    }

                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(player.formatted(track.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                library.toggleFavorite(track.id)
            } label: {
                Label(track.isFavorite ? "Убрать из избранного" : "В избранное",
                      systemImage: track.isFavorite ? "heart.slash" : "heart")
            }
            Divider()
            Button(role: .destructive) {
                library.delete(track)
            } label: {
                Label("Удалить файл", systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(settings.accentColor)

            Text("Ваша медиатека пуста")
                .font(.title2.weight(.bold))

            Text("Загрузите любимую музыку через приложение «Файлы», выберите файлы в разделе «Обзор и импорт» или перенесите треки с компьютера через Finder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
