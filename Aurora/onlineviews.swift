import SwiftUI

// MARK: - Tab 1: Главная

struct HomeView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared

    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var albums: [YandexMusicService.YMAlbumItem] = []
    @State private var isLoading = false
    @State private var showSettings = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 5 { return "Доброй ночи" }
        if h < 12 { return "Доброе утро" }
        if h < 18 { return "Добрый день" }
        return "Добрый вечер"
    }

    private var topFive: [RankedTrack] {
        chart.prefix(5).enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        heroHeader
                        waveHero
                        stationsRow
                        chartSection
                        albumsSection
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AG.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await load() }
        }
    }

    // MARK: Header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting.uppercased())
                .font(AG.text(10, .heavy))
                .tracking(1.8)
                .foregroundStyle(AG.amber)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Слушайте")
                    .font(AG.display(30, .heavy))
                    .foregroundStyle(AG.ink)
                Text("своё")
                    .font(AG.serifAccent(30))
                    .foregroundStyle(AG.amber)
            }

            Text("Без навязанных повторов и лишнего шума")
                .font(AG.text(12.5, .regular))
                .foregroundStyle(AG.inkMuted)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Моя волна

    private var waveHero: some View {
        Button {
            SonivoPlay.wave(YandexMusicService.rotorStations[0])
        } label: {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [AG.amber, AG.flame],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("ПЕРСОНАЛЬНЫЙ ПОТОК")
                            .font(AG.text(10, .heavy))
                            .tracking(1.4)
                            .foregroundStyle(Color.black.opacity(0.62))
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.78))
                    }

                    Spacer(minLength: 0)

                    Text("Моя волна")
                        .font(AG.display(27, .heavy))
                        .foregroundStyle(Color.black.opacity(0.9))

                    Text(ym.waveSubtitle)
                        .font(AG.text(11.5, .semibold))
                        .foregroundStyle(Color.black.opacity(0.66))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(17)
            }
            .frame(height: 158)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: AG.ember.opacity(0.35), radius: 18, y: 9)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: Станции

    private var stationsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Волны", accent: "по настроению")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(YandexMusicService.rotorStations.dropFirst()) { station in
                        Button {
                            SonivoPlay.wave(station)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(
                                        colors: station.gradient.compactMap { Color(hex: $0) },
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    Image(systemName: station.icon)
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(Color.black.opacity(0.72))
                                }
                                .frame(width: 132, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                Text(station.title)
                                    .font(AG.text(13, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(station.subtitle)
                                    .font(AG.text(10.5, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Чарт — 5 треков + все

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                SonivoHeader(title: "Чарт", accent: "сегодня")

                Spacer(minLength: 8)

                NavigationLink {
                    Top100ChartView(title: "Чарт", tracks: chart)
                } label: {
                    SonivoMoreButton(title: "Все")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if isLoading && chart.isEmpty {
                ProgressView()
                    .tint(AG.amber)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(topFive) { row in
                        ChartRowView(rank: row.rank, item: row.item) {
                            SonivoPlay.track(row.item, in: chart)
                        }
                    }
                }

                NavigationLink {
                    Top100ChartView(title: "Топ 100", tracks: chart)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Смотреть все · Топ 100")
                            .font(AG.text(13, .bold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundStyle(AG.amber)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AG.hairline, lineWidth: 0.8)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Свежие релизы

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Свежие", accent: "релизы")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(albums.prefix(12)) { album in
                        Button {
                            SonivoPlay.album(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                                    .frame(width: 142, height: 142)

                                Text(album.displayTitle)
                                    .font(AG.text(13, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(10.5, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 142, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        isLoading = true
        chart = (try? await ym.getChart()) ?? []
        isLoading = false
        albums = (try? await ym.getNewAlbums()) ?? []
    }
}

// MARK: - Tab 2: Новое

struct NewReleasesView: View {
    @StateObject private var ym = YandexMusicService.shared

    @State private var section: NewSection = .fresh
    @State private var albums: [YandexMusicService.YMAlbumItem] = []
    @State private var freshTracks: [YandexMusicService.YMTrackItem] = []
    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var picks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("СВЕЖИЙ ПОТОК")
                                .font(AG.text(10, .heavy))
                                .tracking(1.8)
                                .foregroundStyle(AG.amber)

                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("Всё")
                                    .font(AG.display(30, .heavy))
                                    .foregroundStyle(AG.ink)
                                Text("новое")
                                    .font(AG.serifAccent(30))
                                    .foregroundStyle(AG.amber)
                            }
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(NewSection.allCases) { item in
                                    Button {
                                        withAnimation(.easeOut(duration: 0.2)) { section = item }
                                    } label: {
                                        SonivoChip(title: item.label, icon: item.icon, isActive: section == item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        if isLoading && albums.isEmpty && chart.isEmpty {
                            ProgressView()
                                .tint(AG.amber)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            switch section {
                            case .fresh:
                                albumGrid
                            case .popular:
                                trackList(Array(chart.prefix(30)), ranked: false)
                            case .listening:
                                trackList(picks, ranked: false)
                            case .top100:
                                trackList(chart, ranked: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task { await load() }
        }
    }

    private var albumGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !freshTracks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SonivoHeader(title: "Самое", accent: "свежее", subtitle: "Треки из только вышедших релизов")
                        .padding(.horizontal, 16)

                    VStack(spacing: 2) {
                        ForEach(freshTracks.prefix(8)) { item in
                            ChartRowView(rank: nil, item: item) {
                                SonivoPlay.track(item, in: freshTracks)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SonivoHeader(title: "Новые", accent: "альбомы")
                    .padding(.horizontal, 16)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    spacing: 18
                ) {
                    ForEach(albums) { album in
                        Button {
                            SonivoPlay.album(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                                    .aspectRatio(1, contentMode: .fit)

                                Text(album.displayTitle)
                                    .font(AG.text(13.5, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(11, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func trackList(_ items: [YandexMusicService.YMTrackItem], ranked: Bool) -> some View {
        VStack(spacing: 2) {
            if items.isEmpty {
                Text("Пока нет данных. Послушайте несколько треков — подборка появится.")
                    .font(AG.text(13, .regular))
                    .foregroundStyle(AG.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 40)
            } else if ranked {
                ForEach(items.enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }) { row in
                    ChartRowView(rank: row.rank, item: row.item) {
                        SonivoPlay.track(row.item, in: items)
                    }
                }
            } else {
                ForEach(items) { item in
                    ChartRowView(rank: nil, item: item) {
                        SonivoPlay.track(item, in: items)
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        chart = (try? await ym.getChart()) ?? []
        albums = (try? await ym.getNewAlbums()) ?? []
        isLoading = false
        freshTracks = await ym.getNewTracks(limit: 20)
        picks = await ym.personalPicks(limit: 24)
    }
}

// MARK: - Tab 3: Радио

struct RadioStationsView: View {
    @StateObject private var ym = YandexMusicService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Button {
                            SonivoPlay.wave(YandexMusicService.rotorStations[0])
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(colors: [AG.amber, AG.flame], startPoint: .topLeading, endPoint: .bottomTrailing)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("ПЕРСОНАЛЬНОЕ РАДИО")
                                            .font(AG.text(10, .heavy))
                                            .tracking(1.4)
                                            .foregroundStyle(Color.black.opacity(0.62))
                                        Spacer(minLength: 0)
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 34, weight: .bold))
                                            .foregroundStyle(Color.black.opacity(0.78))
                                    }

                                    Spacer(minLength: 0)

                                    Text("Моя волна")
                                        .font(AG.display(28, .heavy))
                                        .foregroundStyle(Color.black.opacity(0.9))

                                    Text(ym.waveSubtitle)
                                        .font(AG.text(11.5, .semibold))
                                        .foregroundStyle(Color.black.opacity(0.66))
                                        .lineLimit(2)
                                }
                                .padding(18)
                            }
                            .frame(height: 172)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: AG.ember.opacity(0.32), radius: 16, y: 8)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)

                        SonivoHeader(title: "Станции", accent: "по жанрам")
                            .padding(.horizontal, 16)

                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(YandexMusicService.rotorStations.dropFirst()) { station in
                                Button {
                                    SonivoPlay.wave(station)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ZStack {
                                            LinearGradient(
                                                colors: station.gradient.compactMap { Color(hex: $0) },
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                            Image(systemName: station.icon)
                                                .font(.system(size: 32, weight: .semibold))
                                                .foregroundStyle(Color.black.opacity(0.72))
                                        }
                                        .frame(height: 108)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                                        Text(station.title)
                                            .font(AG.text(13.5, .semibold))
                                            .foregroundStyle(AG.ink)
                                            .lineLimit(1)

                                        Text(station.subtitle)
                                            .font(AG.text(10.5, .regular))
                                            .foregroundStyle(AG.inkMuted)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Tab 5: Поиск

struct SearchCatalogView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var ym = YandexMusicService.shared

    @State private var searchText = ""
    @State private var results: [YandexMusicService.YMTrackItem] = []
    @State private var isSearching = false
    @State private var searchError: String? = nil
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

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if searchText.isEmpty {
                            genresGrid
                        }

                        if !localResults.isEmpty {
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
                        }

                        if !results.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SonivoHeader(title: "Из каталога")
                                    .padding(.horizontal, 16)

                                LazyVStack(spacing: 2) {
                                    ForEach(results) { item in
                                        ChartRowView(rank: nil, item: item) {
                                            SonivoPlay.track(item, in: results)
                                        }
                                    }
                                }
                            }
                        }

                        if isSearching {
                            ProgressView()
                                .tint(AG.amber)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        } else if let error = searchError {
                            VStack(spacing: 12) {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(AG.inkMuted)
                                Text(error)
                                    .font(AG.text(15, .semibold))
                                    .foregroundStyle(AG.ink)
                                Button {
                                    performSearch()
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
                            .padding(.vertical, 40)
                        } else if !searchText.isEmpty && results.isEmpty && localResults.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(AG.inkMuted)
                                Text("Ничего не найдено")
                                    .font(AG.text(15, .semibold))
                                    .foregroundStyle(AG.ink)
                                Text("Проверьте название или имя исполнителя.")
                                    .font(AG.text(12.5, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("Поиск")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .searchable(text: $searchText, prompt: "Треки, исполнители, альбомы")
            .onSubmit(of: .search) { performSearch() }
            .onChange(of: searchText) { newValue in
                if newValue.isEmpty {
                    searchTask?.cancel()
                    results = []
                    searchError = nil
                } else {
                    let query = newValue
                    Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard searchText == query else { return }
                        performSearch()
                    }
                }
            }
        }
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
                        performSearch()
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
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            isSearching = true
            searchError = nil
            do {
                let found = try await ym.search(query: query)
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchError = "Не удалось выполнить поиск"
            }
            if !Task.isCancelled {
                isSearching = false
            }
        }
    }
}
