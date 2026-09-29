import SwiftUI

// MARK: - Tab 5: Поиск (глобальный, по всей базе)

struct SearchCatalogView: View {
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared
    @State private var ym = YandexMusicService.shared

    @State private var searchText = ""
    @State private var recentSearches: [String] = UserDefaults.standard.stringArray(forKey: "sonivo_recent_searches") ?? []
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
        Genre(id: "Поп", colors: [SN.amber, SN.flame]),
        Genre(id: "Хип-хоп", colors: SN.Tile.brown),
        Genre(id: "Электроника", colors: SN.Tile.sand),
        Genre(id: "Рок", colors: SN.Tile.crimson),
        Genre(id: "Lo-Fi", colors: SN.Tile.gold),
        Genre(id: "Джаз", colors: SN.Tile.copper)
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
                            if !recentSearches.isEmpty {
                                recentSearchesSection
                            }
                            genresGrid
                        } else {
                            if !suggestions.isEmpty { suggestionsRow }
                            if !results.artists.isEmpty { artistsSection }
                            if !results.albums.isEmpty { albumsSection }
                            if !results.tracks.isEmpty { tracksSection }
                            if !localResults.isEmpty { localSection }

                            if isSearching {
                                SonivoLoadingState(title: "Ищем музыку…")
                            } else if didSearch && isEmptyResult {
                                emptyState
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 84)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Треки, исполнители, альбомы")
            .onSubmit(of: .search) { performSearch(immediate: true) }
            .onChange(of: searchText) { _, newValue in
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
                            .font(SN.text(.caption, .medium))
                            .foregroundStyle(SN.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(SN.card.opacity(0.82)))
                            .overlay(Capsule().strokeBorder(SN.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.94))
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
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))

                                Text(artist.name)
                                    .font(SN.text(.caption, .semibold))
                                    .foregroundStyle(SN.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: 96)
                        }
                        .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
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
                            SonivoArtworkCard(title: album.displayTitle, subtitle: album.artistName, width: 140) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 14)
                            }
                        }
                        .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
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
                    PlaybackCommandRouter.shared.play(track, queue: [track])
                } label: {
                    HStack(spacing: 12) {
                        SmallArtwork(track: track, size: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(SN.text(.subheadline, .semibold))
                                .foregroundStyle(SN.ink)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(SN.text(.caption))
                                .foregroundStyle(SN.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))
            }
        }
        .riseIn(delay: 0.10)
    }

    private var emptyState: some View {
        SonivoEmptyState(
            systemImage: "magnifyingglass",
            title: "Ничего не найдено",
            message: "Проверьте написание или выберите подсказку выше.",
            actionTitle: "Повторить",
            action: { performSearch(immediate: true) }
        )
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
                                .font(SN.display(.subheadline, .heavy))
                                .foregroundStyle(Color.black.opacity(0.82))
                                .padding(13)
                        }
                        .frame(height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(SN.hairline, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
                }
            }
            .padding(.horizontal, 16)
        }
        .riseIn()
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Недавние поиски")
                    .font(SN.text(.body, .bold))
                    .foregroundStyle(SN.ink)
                Spacer()
                Button("Очистить") {
                    withAnimation {
                        recentSearches = []
                        UserDefaults.standard.removeObject(forKey: "sonivo_recent_searches")
                    }
                }
                .font(SN.text(.footnote, .medium))
                .foregroundStyle(SN.inkMuted)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recentSearches, id: \.self) { item in
                        Button {
                            searchText = item
                            performSearch(immediate: true)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(SN.text(.caption2, .bold))
                                    .foregroundStyle(SN.inkMuted)
                                Text(item)
                                    .font(SN.text(.footnote, .medium))
                                    .foregroundStyle(SN.ink)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(SN.card.opacity(0.82)))
                            .overlay(Capsule().strokeBorder(SN.hairline, lineWidth: 0.5))
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.95))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 4)
    }

    private func saveSearchQuery(_ query: String) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(clean) != .orderedSame }
        list.insert(clean, at: 0)
        if list.count > 15 { list = Array(list.prefix(15)) }
        recentSearches = list
        UserDefaults.standard.set(list, forKey: "sonivo_recent_searches")
    }

    private func performSearch(immediate: Bool) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        saveSearchQuery(query)
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
