import SwiftUI

// MARK: - Tab 1: Home (Главная) with Yandex Music

struct HomeView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var settings = SettingsStore.shared

    @State private var ymChart: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // 1. Главные баннеры
                    heroBannerCarousel

                    // 2. Карточка «Моя волна»
                    myWaveHeroCard

                    // 3. Топ-чарт (10 лучших треков с порядковыми номерами)
                    topChartSection

                    // 4. Свежие релизы
                    featuredAlbumsSection
                }
                .padding(.top, 12)
                .padding(.bottom, 130)
            }
            .navigationTitle("Главная")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                await loadData()
            }
        }
    }

    // MARK: - Hero Banners Carousel

    private var heroBannerCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                bannerCard(
                    category: "ПЕРСОНАЛЬНЫЙ ПОТОК",
                    title: "Моя волна",
                    subtitle: "Бесконечный микс на основе ваших вкусов",
                    gradient: [Color(hex: "#FF455B")!, Color(hex: "#9333EA")!],
                    icon: "waveform.badge.sparkles"
                ) {
                    playRotor(YandexMusicService.rotorStations[0])
                }

                bannerCard(
                    category: "ГЛАВНЫЙ ЧАРТ",
                    title: "Топ 100 треков",
                    subtitle: "Самая популярная музыка прямо сейчас",
                    gradient: [Color(hex: "#F97316")!, Color(hex: "#E11D48")!],
                    icon: "flame.fill"
                ) {
                    if let first = ymChart.first { playYM(first) }
                }

                bannerCard(
                    category: "SMART TRANSITIONS",
                    title: "DJ AutoMix",
                    subtitle: "Бесшовное сведение с технологией Bass-Swap",
                    gradient: [Color(hex: "#06B6D4")!, Color(hex: "#3B82F6")!],
                    icon: "sparkles"
                ) {
                    if let first = ymChart.first {
                        playYM(first)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func bannerCard(category: String, title: String, subtitle: String, gradient: [Color], icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(category)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    Spacer()

                    Text(title)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(18)
            }
            .frame(width: 320, height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - «Моя волна» Card

    private var myWaveHeroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Моя волна", systemImage: "waveform.badge.sparkles")
                    .font(.title3.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(YandexMusicService.rotorStations) { station in
                        Button {
                            playRotor(station)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(
                                        colors: station.gradient.compactMap { Color(hex: $0) },
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )

                                    Image(systemName: station.icon)
                                        .font(.system(size: 36, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 140, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

                                Text(station.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)

                                Text(station.subtitle)
                                    .font(.caption2)
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

    // MARK: - Top Chart Ranked List

    private var topChartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Чарт Яндекс Музыки")
                    .font(.title3.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 16)

            if isLoading && ymChart.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(ymChart.prefix(10).enumerated()), id: \.element.id) { index, item in
                        Button {
                            playYM(item)
                        } label: {
                            HStack(spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.headline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(index < 3 ? settings.accentColor : Color.secondary)
                                    .frame(width: 24, alignment: .center)

                                AsyncImage(url: URL(string: item.coverUrlString ?? "")) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        ZStack {
                                            LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                            Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8))
                                        }
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)

                                    Text(item.artistName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Menu {
                                    Button {
                                        Task {
                                            if let streamURL = try? await ym.getDirectStreamURL(for: item.id) {
                                                var t = ym.convertToTrack(item)
                                                t.streamUrlString = streamURL.absoluteString
                                                await library.saveOnlineTrackLocally(track: t)
                                            }
                                        }
                                    } label: {
                                        Label("Скачать на iPhone", systemImage: "arrow.down.circle")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 32, height: 32)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Featured Albums & Singles

    private var featuredAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Популярные релизы")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(ymChart.dropFirst(10).prefix(8))) { item in
                        Button {
                            playYM(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: URL(string: item.coverUrlString ?? "")) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Color.gray.opacity(0.3)
                                    }
                                }
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: .black.opacity(0.16), radius: 6, y: 3)

                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)

                                Text(item.artistName)
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

    private func playYM(_ item: YandexMusicService.YMTrackItem) {
        Task {
            if let streamURL = try? await ym.getDirectStreamURL(for: item.id) {
                var t = ym.convertToTrack(item)
                t.streamUrlString = streamURL.absoluteString
                let queue = ymChart.map { ym.convertToTrack($0) }
                player.play(t, newQueue: queue)
            }
        }
    }

    private func playRotor(_ station: YandexMusicService.StationOption) {
        Task {
            if let tracks = try? await ym.getStationTracks(stationId: station.stationId), let first = tracks.first {
                if let streamURL = try? await ym.getDirectStreamURL(for: first.id) {
                    var t = ym.convertToTrack(first)
                    t.streamUrlString = streamURL.absoluteString
                    let queue = tracks.map { ym.convertToTrack($0) }
                    player.play(t, newQueue: queue)
                }
            }
        }
    }

    private func loadData() async {
        isLoading = true
        ymChart = (try? await ym.getChart()) ?? []
        isLoading = false
    }

    private func formatTime(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Tab 2: New (Новинки)

struct NewReleasesView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared
    @State private var newTracks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Свежие альбомы и синглы")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 16)

                    if isLoading && newTracks.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                            ForEach(newTracks) { item in
                                Button {
                                    Task {
                                        if let streamURL = try? await ym.getDirectStreamURL(for: item.id) {
                                            var t = ym.convertToTrack(item)
                                            t.streamUrlString = streamURL.absoluteString
                                            let queue = newTracks.map { ym.convertToTrack($0) }
                                            player.play(t, newQueue: queue)
                                        }
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        AsyncImage(url: URL(string: item.coverUrlString ?? "")) { phase in
                                            if let img = phase.image {
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                ZStack {
                                                    LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                                                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8))
                                                }
                                            }
                                        }
                                        .frame(height: 165)
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.headline.weight(.semibold))
                                                .lineLimit(1)
                                                .foregroundStyle(.primary)

                                            Text(item.artistName)
                                                .font(.subheadline)
                                                .lineLimit(1)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 130)
            }
            .navigationTitle("Новинки")
            .task {
                isLoading = true
                newTracks = (try? await ym.getChart()) ?? []
                isLoading = false
            }
        }
    }
}

// MARK: - Tab 3: Radio (Радио)

struct RadioStationsView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Big Interactive «Моя волна» Header
                    Button {
                        playYMRadio(YandexMusicService.rotorStations[0])
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(
                                colors: [Color(hex: "#FF455B")!, Color(hex: "#9333EA")!],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Label("ПЕРСОНАЛЬНОЕ РАДИО", systemImage: "sparkles")
                                        .font(.system(size: 11, weight: .heavy))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 36, weight: .bold))
                                        .foregroundStyle(.white)
                                }

                                Spacer()

                                Text("Моя волна")
                                    .font(.title.weight(.heavy))
                                    .foregroundStyle(.white)

                                Text("Нажмите, чтобы включить непрерывный поток любимой музыки")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(2)
                            }
                            .padding(20)
                        }
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)

                    // Thematic Stations Grid
                    Text("Тематические станции")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                        ForEach(YandexMusicService.rotorStations.dropFirst()) { station in
                            Button {
                                playYMRadio(station)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        LinearGradient(
                                            colors: station.gradient.compactMap { Color(hex: $0) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )

                                        Image(systemName: station.icon)
                                            .font(.system(size: 36, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .frame(height: 115)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(station.title)
                                            .font(.headline.weight(.semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)

                                        Text(station.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 10)
                .padding(.bottom, 130)
            }
            .navigationTitle("Радио")
        }
    }

    private func playYMRadio(_ station: YandexMusicService.StationOption) {
        Task {
            if let tracks = try? await ym.getStationTracks(stationId: station.stationId), let first = tracks.first {
                if let streamURL = try? await ym.getDirectStreamURL(for: first.id) {
                    var t = ym.convertToTrack(first)
                    t.streamUrlString = streamURL.absoluteString
                    let queue = tracks.map { ym.convertToTrack($0) }
                    player.play(t, newQueue: queue)
                }
            }
        }
    }
}

// MARK: - Tab 5: Search (Поиск) Across Yandex Music & Local Media

struct SearchCatalogView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var ym = YandexMusicService.shared
    @StateObject private var settings = SettingsStore.shared

    @State private var searchText = ""
    @State private var ymResults: [YandexMusicService.YMTrackItem] = []
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
                VStack(alignment: .leading, spacing: 22) {
                    if searchText.isEmpty {
                        searchCategoriesView
                    }

                    // Local Matches
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

                    // Yandex Music Matches
                    if !ymResults.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "music.note")
                                    .foregroundStyle(Color(hex: "#FF455B") ?? .pink)
                                Text("Яндекс Музыка")
                                    .font(.headline.weight(.bold))
                            }
                            .padding(.horizontal, 16)

                            LazyVStack(spacing: 4) {
                                ForEach(ymResults) { item in
                                    Button {
                                        Task {
                                            if let streamURL = try? await ym.getDirectStreamURL(for: item.id) {
                                                var t = ym.convertToTrack(item)
                                                t.streamUrlString = streamURL.absoluteString
                                                let queue = ymResults.map { ym.convertToTrack($0) }
                                                player.play(t, newQueue: queue)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            AsyncImage(url: URL(string: item.coverUrlString ?? "")) { phase in
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
                                                Text(item.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "play.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(Color(hex: "#FF455B") ?? .pink)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if isSearching {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 130)
            }
            .navigationTitle("Поиск")
            .searchable(text: $searchText, prompt: "Поиск в Яндекс Музыке и медиатеке")
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .onChange(of: searchText) { newValue in
                if newValue.isEmpty {
                    ymResults = []
                } else {
                    let query = newValue
                    Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        guard searchText == query else { return }
                        await performSearch()
                    }
                }
            }
        }
    }

    private var searchCategoriesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Жанры и категории")
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 16)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                let cats = [
                    ("Поп", [Color.pink, Color.orange]),
                    ("Хип-хоп", [Color.orange, Color.red]),
                    ("Электроника", [Color.blue, Color.cyan]),
                    ("Рок", [Color.red, Color.purple]),
                    ("Lo-Fi & Chill", [Color.teal, Color.indigo]),
                    ("Джаз", [Color.yellow, Color.brown])
                ]
                ForEach(cats, id: \.0) { cat in
                    Button {
                        searchText = cat.0
                        Task { await performSearch() }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: cat.1, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(cat.0)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(14)
                        }
                        .frame(height: 75)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func performSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        ymResults = (try? await ym.search(query: query)) ?? []
        isSearching = false
    }
}
