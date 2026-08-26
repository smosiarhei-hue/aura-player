import SwiftUI

// MARK: - Tab 5: Поиск (глобальный, по всей базе)

struct SearchCatalogView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var ym = YandexMusicService.shared

    @State private var searchText = ""
    @State private var results = YandexMusicService.GlobalSearchResults()
    @State private var suggestions: [String] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var searchTask: Task<Void, Never>? = nil

    private struct Genre: Identifiable {
        let id: String
        let colors: [Color]
    }

    private let genres: [Genre] = [
        Genre(id: "Поп", colors: [AG.amber, AG.flame]),
        Genre(id: "Хип-хоп", colors: [AG.ember, Color(hex: "#7C2D12") ?? .brown]),
        Genre(id: "Электроника", colors: [Color(hex: "#FDE68A") ?? .yellow, AG.ember]),
        Genre(id: "Рок", colors: [Color(hex: "#B91C1C") ?? .red, Color(hex: "#7C2D12") ?? .brown]),
        Genre(id: "Lo-Fi", colors: [Color(hex: "#FCD34D") ?? .yellow, Color(hex: "#B45309") ?? .orange]),
        Genre(id: "Джаз", colors: [Color(hex: "#FB923C") ?? .orange, Color(hex: "#9A3412") ?? .brown])
    ]

    private var localResults: [Track] {
        guard !searchText.isEmpty else { return [] }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isEmptyResult: Bool {
        results.tracks.isEmpty && results.artists.isEmpty && results.albums.isEmpty && localResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if searchText.isEmpty {
                            genresGrid
                        } else {
                            if !suggestions.isEmpty { suggestionsRow }
                            if !results.artists.isEmpty { artistsSection }
                            if !results.albums.isEmpty { albumsSection }
                            if !results.tracks.isEmpty { tracksSection }
                            if !localResults.isEmpty { localSection }

                            if isSearching {
                                ProgressView()
                                    .tint(AG.amber)
                                    .frame(maxWidth: .infinity, minHeight: 100)
                            } else if didSearch && isEmptyResult {
                                emptyState
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Треки, исполнители, альбомы")
            .onSubmit(of: .search) { performSearch(immediate: true) }
            .onChange(of: searchText) { newValue in
                let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                searchTask?.cancel()
                if query.isEmpty {
                    results = YandexMusicService.GlobalSearchResults()
                    suggestions = []
                    didSearch = false
                    isSearching = false
                } else {
                    performSearch(immediate: false)
                }
            }
        }
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        searchText = suggestion
                        performSearch(immediate: true)
                    } label: {
                        Text(suggestion)
                            .font(AG.text(12, .medium))
                            .foregroundStyle(AG.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(AG.hairline, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .riseIn()
    }

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Артисты")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(results.artists.prefix(12)) { artist in
                        NavigationLink {
                            ArtistView(artistId: artist.id)
                        } label: {
                            VStack(spacing: 8) {
                                RemoteArtwork(urlString: artist.coverUrlString, corner: 999)
                                    .frame(width: 96, height: 96)

                                Text(artist.name)
                                    .font(AG.text(12, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: 96)
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .riseIn()
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Альбомы")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(results.albums.prefix(12)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 14)
                                    .frame(width: 140, height: 140)

                                Text(album.displayTitle)
                                    .font(AG.text(13, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(11, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .riseIn(delay: 0.05)
    }

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SonivoHeader(title: "Треки")
                .padding(.horizontal, 16)

            LazyVStack(spacing: 2) {
                ForEach(results.tracks) { item in
                    ChartRowView(rank: nil, item: item) {
                        SonivoPlay.track(item, in: results.tracks)
                    }
                }
            }
        }
        .riseIn(delay: 0.08)
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SonivoHeader(title: "В медиатеке")
                .padding(.horizontal, 16)

            ForEach(localResults) { track in
                Button {
                    player.play(track)
                } label: {
                    HStack(spacing: 12) {
                        SmallArtwork(track: track, size: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(AG.text(14, .semibold))
                                .foregroundStyle(AG.ink)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(AG.text(11.5, .regular))
                                .foregroundStyle(AG.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .riseIn(delay: 0.10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AG.inkMuted)
            Text("Ничего не найдено")
                .font(AG.text(16, .semibold))
                .foregroundStyle(AG.ink)
            Text("Проверьте написание или выберите подсказку выше.")
                .font(AG.text(12.5, .regular))
                .foregroundStyle(AG.inkMuted)
                .multilineTextAlignment(.center)
            Button {
                performSearch(immediate: true)
            } label: {
                Text("Повторить")
                    .font(AG.text(13, .bold))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(AG.emberGradient))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
    }

    private var genresGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Жанры", accent: "и настроения")
                .padding(.horizontal, 16)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(genres) { genre in
                    Button {
                        searchText = genre.id
                        performSearch(immediate: true)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: genre.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(genre.id)
                                .font(AG.display(15, .heavy))
                                .foregroundStyle(Color.black.opacity(0.82))
                                .padding(13)
                        }
                        .frame(height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(AG.hairline, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(GlassPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
        .riseIn()
    }

    private func performSearch(immediate: Bool) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()

        searchTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            }

            isSearching = true
            suggestions = await ym.searchSuggestions(query: query)
            let found = await ym.searchAllFixed(query: query)
            guard !Task.isCancelled else { return }
            results = found
            didSearch = true
            isSearching = false
        }
    }
}
