import SwiftUI

// MARK: - Tab 1: Home (Главная)

struct HomeView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var trendingTracks: [JamendoService.JTrack] = []
    @State private var isLoading = false
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Featured Banner (Apple Music Style)
                    featuredCarousel

                    // Top Charts / Слушать сейчас
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Слушать сейчас")
                                .font(.title3.weight(.bold))
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        if isLoading && trendingTracks.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(Array(trendingTracks.prefix(10))) { item in
                                        Button {
                                            playTrack(item)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                AsyncImage(url: URL(string: item.coverUrl ?? "")) { phase in
                                                    if let img = phase.image {
                                                        img.resizable().aspectRatio(contentMode: .fill)
                                                    } else {
                                                        ZStack {
                                                            LinearGradient(colors: [.teal, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                                                            Image(systemName: "music.note").foregroundStyle(.white)
                                                        }
                                                    }
                                                }
                                                .frame(width: 140, height: 140)
                                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

                                                Text(item.title)
                                                    .font(.subheadline.weight(.semibold))
                                                    .lineLimit(1)
                                                    .foregroundStyle(.primary)

                                                Text(item.artist)
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

                    // Popular Tracks List
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Популярные треки")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 16)

                        LazyVStack(spacing: 4) {
                            ForEach(Array(trendingTracks.dropFirst(10))) { item in
                                Button {
                                    playTrack(item)
                                } label: {
                                    HStack(spacing: 12) {
                                        AsyncImage(url: URL(string: item.coverUrl ?? "")) { phase in
                                            if let img = phase.image {
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Color.gray.opacity(0.3)
                                            }
                                        }
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.body.weight(.medium))
                                                .lineLimit(1)
                                                .foregroundStyle(.primary)
                                            Text(item.artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "play.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 130)
            }
            .navigationTitle("Главная")
            .task { await load() }
        }
    }

    private var featuredCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<3) { i in
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: i == 0 ? [Color.purple, Color.blue] : (i == 1 ? [Color.orange, Color.pink] : [Color.teal, Color.indigo]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(i == 0 ? "ГОРЯЧИЕ НОВИНКИ" : (i == 1 ? "ТОП ЧАРТ 2026" : "DJ AUTOMIX СЕССИЯ"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.8))

                            Text(i == 0 ? "Главные мировые треки" : (i == 1 ? "Тренды Jamendo Music" : "Умный микс без пауз"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(.white)
                        }
                        .padding(20)
                    }
                    .frame(width: 320, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func playTrack(_ item: JamendoService.JTrack) {
        let t = JamendoService.convertToTrack(item)
        player.play(t)
    }

    private func load() async {
        isLoading = true
        do {
            trendingTracks = try await JamendoService.trending(limit: 30)
        } catch {
            errorText = "Не удалось загрузить чарты"
        }
        isLoading = false
    }
}

// MARK: - Tab 2: New (Новинки)

struct NewReleasesView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var newTracks: [JamendoService.JTrack] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Свежие релизы этой недели")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    if isLoading && newTracks.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(newTracks) { item in
                                Button {
                                    let t = JamendoService.convertToTrack(item)
                                    player.play(t)
                                } label: {
                                    HStack(spacing: 14) {
                                        AsyncImage(url: URL(string: item.coverUrl ?? "")) { phase in
                                            if let img = phase.image {
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Color.gray.opacity(0.3)
                                            }
                                        }
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title)
                                                .font(.body.weight(.medium))
                                                .lineLimit(1)
                                                .foregroundStyle(.primary)
                                            Text(item.artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.circle")
                                            .font(.title3)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.bottom, 130)
            }
            .navigationTitle("Новинки")
            .task {
                isLoading = true
                newTracks = (try? await JamendoService.newReleases(limit: 40)) ?? []
                isLoading = false
            }
        }
    }
}

// MARK: - Tab 3: Radio (Радио)

struct RadioStationsView: View {
    @StateObject private var player = PlayerCore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Тематические станции и непрерывный эфир")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(JamendoService.stations) { station in
                            Button {
                                playStation(station)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        LinearGradient(
                                            colors: station.coverGradient.compactMap { Color(hex: $0) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )

                                        Image(systemName: station.iconName)
                                            .font(.system(size: 36, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .frame(height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(station.title)
                                            .font(.headline.weight(.semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)

                                        Text(station.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 130)
            }
            .navigationTitle("Радио")
        }
    }

    private func playStation(_ station: JamendoService.RadioStation) {
        Task {
            if let tracks = try? await JamendoService.tracksForStation(station), let first = tracks.first {
                let queue = tracks.map { JamendoService.convertToTrack($0) }
                player.play(queue[0], newQueue: queue)
            }
        }
    }
}

// MARK: - Tab 5: Search (Поиск)

struct SearchCatalogView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @State private var searchText = ""
    @State private var results: [JamendoService.JTrack] = []
    @State private var isSearching = false

    var localResults: [Track] {
        guard !searchText.isEmpty else { return [] }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Local tracks match
                    if !localResults.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("В вашей медиатеке")
                                .font(.headline.weight(.semibold))
                                .padding(.horizontal, 16)

                            ForEach(localResults) { track in
                                Button {
                                    player.play(track)
                                } label: {
                                    HStack(spacing: 12) {
                                        SmallArtwork(track: track, size: 44)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Online tracks from Jamendo
                    VStack(alignment: .leading, spacing: 10) {
                        if !results.isEmpty {
                            Text("Онлайн-каталог (Jamendo)")
                                .font(.headline.weight(.semibold))
                                .padding(.horizontal, 16)
                        }

                        if isSearching {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                        } else {
                            LazyVStack(spacing: 4) {
                                ForEach(results) { item in
                                    Button {
                                        let t = JamendoService.convertToTrack(item)
                                        player.play(t)
                                    } label: {
                                        HStack(spacing: 12) {
                                            AsyncImage(url: URL(string: item.coverUrl ?? "")) { phase in
                                                if let img = phase.image {
                                                    img.resizable().aspectRatio(contentMode: .fill)
                                                } else {
                                                    Color.gray.opacity(0.3)
                                                }
                                            }
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "play.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 130)
            }
            .navigationTitle("Поиск")
            .searchable(text: $searchText, prompt: "Артисты, треки, альбомы")
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .onChange(of: searchText) { _ in
                if searchText.isEmpty { results = [] }
            }
        }
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        results = (try? await JamendoService.search(query: searchText)) ?? []
        isSearching = false
    }
}
