import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library View (Apple Music Style with Media Scanning & Settings)

struct LibraryView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var showSettings = false
    @State private var showFilePicker = false

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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await library.scanSystemMediaLibrary() }
                        } label: {
                            Label("Сканировать Apple Music на iPhone", systemImage: "music.note.house")
                        }

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Выбрать из «Файлов»", systemImage: "folder.badge.plus")
                        }

                        Button {
                            Task { await library.rescan() }
                        } label: {
                            Label("Пересканировать память", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    library.importFromPicker(urls: urls)
                }
            }
        }
    }

    // MARK: - Main Content

    private var mainLibraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Quick Media Scan Bar
                mediaScanActionCard

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
            .padding(.bottom, 130)
        }
    }

    // MARK: - Media Scan Card

    private var mediaScanActionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(settings.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Импорт сохраненной музыки")
                    .font(.subheadline.weight(.semibold))
                Text("Сканируйте медиатеку iPhone или выберите файлы")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await library.scanSystemMediaLibrary() }
            } label: {
                Text("Сканировать")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.accentColor)
        }
        .liquidGlass(corner: 16, padding: 12)
        .padding(.horizontal, 16)
    }

    // MARK: - Recently Added Section

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

            Text("Нажмите кнопку ниже, чтобы импортировать треки из медиатеки Apple Music на вашем iPhone или загрузите файлы через приложение «Файлы».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                Task { await library.scanSystemMediaLibrary() }
            } label: {
                Label("Сканировать медиатеку iPhone", systemImage: "iphone.and.arrow.forward")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(settings.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
