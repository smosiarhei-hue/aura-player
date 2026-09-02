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

// MARK: - Tab 3: Моя волна
//
// Rebuilt to match the Yandex Music "Моя волна" screen: a full-bleed dark
// canvas with a giant soft multi-colour glow behind a big circular play
// button, the live track pill right under it, and a row of mood/station
// bubbles - instead of the old flat single-gradient "radio" card.

struct RadioStationsView: View {
    @State private var ym = YandexMusicService.shared
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared

    private var moodStation: YandexMusicService.StationOption { ym.waveMoodStation }

    private var moodColors: [Color] {
        let colors = moodStation.gradient.compactMap { Color(hex: $0) }
        return colors.isEmpty ? [AG.amber, AG.flame] : colors
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        waveHero
                            .riseIn()

                        if let track = player.currentTrack {
                            currentTrackPill(track)
                                .padding(.horizontal, 16)
                                .riseIn(delay: 0.05)
                        }

                        moodBubbleRow
                            .riseIn(delay: 0.08)

                        SonivoHeader(title: "Станции", accent: "по жанрам")
                            .padding(.horizontal, 16)
                            .riseIn(delay: 0.12)

                        stationsGrid
                            .riseIn(delay: 0.16)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 22)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
    }

    // Giant radial glow behind a big circular play button, matching the
    // reference screen's hero layout. Colour comes from the real mood
    // station gradient (the same source homeview's small waveHero card
    // already uses), not a fixed amber card.
    private var waveHero: some View {
        ZStack {
            RadialGradient(
                colors: [moodColors.first ?? AG.amber, .clear],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 6,
                endRadius: 230
            )
            .blur(radius: 6)

            RadialGradient(
                colors: [(moodColors.count > 1 ? moodColors[1] : AG.flame).opacity(0.9), .clear],
                center: UnitPoint(x: 0.28, y: 0.30),
                startRadius: 4,
                endRadius: 160
            )
            .blendMode(.plusLighter)

            RadialGradient(
                colors: [(moodColors.count > 2 ? moodColors[2] : AG.amber).opacity(0.7), .clear],
                center: UnitPoint(x: 0.74, y: 0.34),
                startRadius: 4,
                endRadius: 150
            )
            .blendMode(.plusLighter)

            VStack(spacing: 22) {
                Text("Моя волна")
                    .font(AG.display(38, .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 4)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    SonivoPlay.wave(moodStation)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(width: 86, height: 86)
                        .background(Circle().fill(moodColors.first ?? AG.amber))
                        .shadow(color: (moodColors.first ?? AG.amber).opacity(0.55), radius: 22, y: 8)
                }
                .buttonStyle(GlassPressStyle())
                .accessibilityLabel("Запустить Мою волну")
            }
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
    }

    private func currentTrackPill(_ track: Track) -> some View {
        HStack(spacing: 10) {
            SmallArtwork(track: track, size: 34)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text("\(track.artist) — \(track.title)")
                .font(AG.text(13.5, .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                library.toggleFavorite(track)
            } label: {
                Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(library.isTrackFavorite(track) ? Color.pink : .white.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8))
    }

    // Colourful mood/station bubbles under the hero, echoing the reference
    // screen's row of quick-pick chips.
    private var moodBubbleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(YandexMusicService.rotorStations) { station in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        SonivoPlay.wave(station)
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                Circle().fill(
                                    LinearGradient(
                                        colors: station.gradient.compactMap { Color(hex: $0) },
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                Image(systemName: station.icon)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.72))
                            }
                            .frame(width: 64, height: 64)

                            Text(station.title)
                                .font(AG.text(11, .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .frame(width: 74)
                        }
                    }
                    .buttonStyle(GlassPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var stationsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
            spacing: 14
        ) {
            ForEach(YandexMusicService.rotorStations.dropFirst()) { station in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
                        )

                        Text(station.title)
                            .font(AG.text(13.5, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(station.subtitle)
                            .font(AG.text(10.5, .regular))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(GlassPressStyle())
            }
        }
        .padding(.horizontal, 16)
    }
}
