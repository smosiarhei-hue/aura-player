import SwiftUI

// MARK: - Tab 2: Новое
// (Главная переехала в homeview.swift, Поиск — в searchviews.swift)

struct NewReleasesView: View {
    @State private var ym = YandexMusicService.shared

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
                        .riseIn()

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(NewSection.allCases) { item in
                                    Button {
                                        withAnimation(AG.fastSpring) { section = item }
                                    } label: {
                                        SonivoChip(title: item.label, icon: item.icon, isActive: section == item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .riseIn(delay: 0.05)

                        if isLoading && albums.isEmpty && chart.isEmpty {
                            ProgressView()
                                .tint(AG.amber)
                                .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            switch section {
                            case .fresh:
                                albumGrid
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            case .popular:
                                trackList(Array(chart.prefix(30)), ranked: false)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            case .listening:
                                trackList(picks, ranked: false)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            case .top100:
                                trackList(chart, ranked: true)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
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
                        .buttonStyle(GlassPressStyle())
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
    @State private var ym = YandexMusicService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Button {
                            SonivoPlay.wave(ym.waveMoodStation)
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .strokeBorder(AG.hairline, lineWidth: 0.8)
                            )
                            .overlay(ShimmerOverlay(corner: 24))
                            .pulsingGlow(AG.ember)
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(GlassPressStyle())
                        .riseIn()

                        SonivoHeader(title: "Станции", accent: "по жанрам")
                            .padding(.horizontal, 16)
                            .riseIn(delay: 0.05)

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
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .strokeBorder(AG.hairline, lineWidth: 0.8)
                                        )

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
                                .buttonStyle(GlassPressStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                        .riseIn(delay: 0.10)
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
