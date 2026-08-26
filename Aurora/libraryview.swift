import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library View (Медиатека — Плейлисты, Избранное, Полноценное управление)

struct LibraryView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared

    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var showSettings = false
    @State private var showFilePicker = false
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistTitle = ""

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "Все песни", favorites = "Избранное", playlists = "Плейлисты", recent = "Недавние"
        var id: String { rawValue }
    }

    var filteredTracks: [Track] {
        var list = library.tracks
        switch filter {
        case .all, .playlists: break
        case .favorites: list = list.filter { $0.isFavorite || library.isTrackFavorite($0) }
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
                if library.tracks.isEmpty && library.playlists.isEmpty {
                    emptyStateView
                } else {
                    mainLibraryContent
                }
            }
            .navigationTitle("Медиатека")
            .searchable(text: $searchText, prompt: "Поиск по песням и плейлистам")
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
                            showNewPlaylistAlert = true
                        } label: {
                            Label("Создать плейлист", systemImage: "plus.rectangle.on.rectangle")
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
            .alert("Новый плейлист", isPresented: $showNewPlaylistAlert) {
                TextField("Название плейлиста", text: $newPlaylistTitle)
                Button("Создать") {
                    library.createPlaylist(title: newPlaylistTitle)
                    newPlaylistTitle = ""
                }
                Button("Отмена", role: .cancel) { newPlaylistTitle = "" }
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

                // Filter Tabs (Все песни, Избранное, Плейлисты, Недавние)
                filterChips

                // Playlists Section (if selected)
                if filter == .playlists {
                    playlistsSection
                } else {
                    // Recently Added Albums / Tracks Grid
                    if filter == .all && searchText.isEmpty && library.tracks.count >= 2 {
                        recentlyAddedSection
                    }

                    // Songs List
                    VStack(spacing: 2) {
                        ForEach(filteredTracks) { track in
                            trackRow(track)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Media Scan Card

    private var mediaScanActionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(settings.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Импорт музыки с телефона")
                    .font(.subheadline.weight(.semibold))
                Text("Выберите аудиофайлы через «Файлы»")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                showFilePicker = true
            } label: {
                Text("Выбрать файлы")
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

    // MARK: - Playlists Section

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ваши плейлисты")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("+ Создать") {
                    showNewPlaylistAlert = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(settings.accentColor)
            }
            .padding(.horizontal, 16)

            if library.playlists.isEmpty {
                Text("Плейлистов пока нет. Нажмите «Создать», чтобы собрать подборку.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                    ForEach(library.playlists) { playlist in
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                LinearGradient(
                                    colors: playlist.coverGradient.compactMap { Color(hex: $0) },
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )

                                Image(systemName: "music.note.list")
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

                            Text(playlist.title)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .foregroundStyle(.primary)

                            Text("\(playlist.trackIds.count) треков")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                library.deletePlaylist(playlist)
                            } label: {
                                Label("Удалить плейлист", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
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

                        if library.isTrackFavorite(track) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
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
                library.toggleFavorite(track)
            } label: {
                Label(library.isTrackFavorite(track) ? "Убрать из избранного" : "В избранное",
                      systemImage: library.isTrackFavorite(track) ? "star.slash" : "star")
            }

            if !library.playlists.isEmpty {
                Menu("Добавить в плейлист") {
                    ForEach(library.playlists) { p in
                        Button(p.title) {
                            library.addTrackToPlaylist(track: track, playlistId: p.id)
                        }
                    }
                }
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

            Text("Загрузите аудиофайлы через приложение «Файлы», чтобы начать слушать музыку.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showFilePicker = true
            } label: {
                Label("Выбрать из «Файлов»", systemImage: "folder.badge.plus")
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
