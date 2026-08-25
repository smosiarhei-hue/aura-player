import SwiftUI

// MARK: - Tab 1: Home (Главная) with Yandex Music & Jamendo

struct HomeView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared
    @State private var ymChart: [YandexMusicService.YMTrackItem] = []
    @State private var jamendoTrending: [JamendoService.JTrack] = []
    @State private var isLoading = false
    @State private var showYMTokenAlert = false
    @State private var tokenInput = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Top Hero Banner
                    featuredCarousel

                    // «Моя волна» (Yandex Music Smart Wave & Radio)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Моя волна и станции", systemImage: "waveform.badge.sparkles")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(YandexMusicService.rotorStations) { station in
                                    Button {
                                        playYMRotor(station)
                                    } label: {
                                        ZStack(alignment: .bottomLeading) {
                                            LinearGradient(
                                                colors: station.gradient.compactMap { Color(hex: $0) },
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )

                                            VStack(alignment: .leading, spacing: 4) {
                                                Image(systemName: station.icon)
                                                    .font(.title2.weight(.bold))
                                                    .foregroundStyle(.white)

                                                Spacer()

                                                Text(station.title)
                                                    .font(.headline.weight(.heavy))
                                                    .foregroundStyle(.white)

                                                Text(station.subtitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(.white.opacity(0.85))
                                                    .lineLimit(1)
                                            }
                                            .padding(14)
                                        }
                                        .frame(width: 160, height: 130)
                                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // Чарт Яндекс Музыки (Top Russia & Global)
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
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(Array(ymChart.prefix(10))) { item in
                                        Button {
                                            playYMTrack(item)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                AsyncImage(url: URL(string: item.coverUrlString ?? "")) { phase in
                                                    if let img = phase.image {
                                                        img.resizable().aspectRatio(contentMode: .fill)
                                                    } else {
                                                        ZStack {
                                                            LinearGradient(colors: [.red, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
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

                    // Слушать сейчас (Jamendo)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Мировые треки и новинки")
                            .font(.title3.weight(.bold))
                            .padding(.horizontal, 16)

                        LazyVStack(spacing: 4) {
                            ForEach(jamendoTrending.prefix(15)) { item in
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
                                        Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.secondary)
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
            .task { await loadAll() }
        }
    }

    private var featuredCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(0..<3) { i in
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: i == 0 ? [Color(hex: "#FF455B")!, Color(hex: "#6366F1")!] : (i == 1 ? [Color.orange, Color.pink] : [Color.teal, Color.indigo]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(i == 0 ? "ЯНДЕКС МУЗЫКА И ОНЛАЙН" : (i == 1 ? "ТОП ЧАРТ РОССИИ И МИРА" : "DJ AUTOMIX BASS-SWAP"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white.opacity(0.85))

                            Text(i == 0 ? "Слушайте треки без ограничений" : (i == 1 ? "Свежие треки этой недели" : "Сведение треков в реальном времени"))
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(.white)
                        }
                        .padding(20)
                    }
                    .frame(width: 320, height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func playYMTrack(_ item: YandexMusicService.YMTrackItem) {
        Task {
            if let streamURL = try? await ym.getDirectStreamURL(for: item.id) {
                var t = ym.convertToTrack(item)
                t.streamUrlString = streamURL.absoluteString
                player.play(t)
            }
        }
    }

    private func playYMRotor(_ station: YandexMusicService.StationOption) {
        Task {
            if let tracks = try? await ym.getStationTracks(stationId: station.stationId), let first = tracks.first {
                if let streamURL = try? await ym.getDirectStreamURL(for: first.id) {
                    var t = ym.convertToTrack(first)
                    t.streamUrlString = streamURL.absoluteString
                    player.play(t)
                }
            }
        }
    }

    private func loadAll() async {
        isLoading = true
        ymChart = (try? await ym.getChart()) ?? []
        jamendoTrending = (try? await JamendoService.trending(limit: 20)) ?? []
        isLoading = false
    }
}

// MARK: - Tab 2: New (Новинки)

struct NewReleasesView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var ym = YandexMusicService.shared
    @State private var ymTracks: [YandexMusicService.YMTrackItem] = []
    @State private var jamendoTracks: [JamendoService.JTrack] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Свежие релизы Яндекс Музыки и мировые треки")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    if isLoading && ymTracks.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(ymTracks) { item in
                                Button {
                                    Task {
                                        if let streamURL = try? await ym.getDirectStreamURL(for: item.id) {
                                            var t = ym.convertToTrack(item)
                                            t.streamUrlString = streamURL.absoluteString
                                            player.play(t)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 14) {
                                        AsyncImage(url: URL(string: item.coverUrlString ?? "")) { phase in
                                            if let img = phase.image {
                                                img.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Color.gray.opacity(0.3)
                                            }
                                        }
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                            Text(item.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                .padding(.bottom, 130)
            }
            .navigationTitle("Новинки")
            .task {
                isLoading = true
                ymTracks = (try? await ym.getChart()) ?? []
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
                VStack(alignment: .leading, spacing: 18) {
                    Text("«Моя волна» и жанровые радиостанции")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    // Yandex Rotor Cards
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(YandexMusicService.rotorStations) { station in
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
                                            .font(.system(size: 38, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .frame(height: 120)
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
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        // Jamendo Genre Stations
                        ForEach(JamendoService.stations) { station in
                            Button {
                                Task {
                                    if let tracks = try? await JamendoService.tracksForStation(station), let first = tracks.first {
                                        let queue = tracks.map { JamendoService.convertToTrack($0) }
                                        player.play(queue[0], newQueue: queue)
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        LinearGradient(
                                            colors: station.coverGradient.compactMap { Color(hex: $0) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )

                                        Image(systemName: station.iconName)
                                            .font(.system(size: 38, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .frame(height: 120)
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

    private func playYMRadio(_ station: YandexMusicService.StationOption) {
        Task {
            if let tracks = try? await ym.getStationTracks(stationId: station.stationId), let first = tracks.first {
                if let streamURL = try? await ym.getDirectStreamURL(for: first.id) {
                    var t = ym.convertToTrack(first)
                    t.streamUrlString = streamURL.absoluteString
                    player.play(t)
                }
            }
        }
    }
}

// MARK: - Tab 5: Search (Поиск) Across Yandex Music, Jamendo & Local Files

struct SearchCatalogView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var ym = YandexMusicService.shared

    @State private var searchText = ""
    @State private var ymResults: [YandexMusicService.YMTrackItem] = []
    @State private var jamendoResults: [JamendoService.JTrack] = []
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
                                    .foregroundStyle(Color(hex: "#FF455B")!)
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
                                                player.play(t)
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
                                                .foregroundStyle(Color(hex: "#FF455B")!)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Jamendo Global Matches
                    if !jamendoResults.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Jamendo Free Tracks")
                                .font(.headline.weight(.semibold))
                                .padding(.horizontal, 16)

                            LazyVStack(spacing: 4) {
                                ForEach(jamendoResults) { item in
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
            .onChange(of: searchText) { _ in
                if searchText.isEmpty {
                    ymResults = []
                    jamendoResults = []
                }
            }
        }
    }

    private func performSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        ymResults = (try? await ym.search(query: searchText)) ?? []
        jamendoResults = (try? await JamendoService.search(query: searchText)) ?? []
        isSearching = false
    }
}
