import SwiftUI

// MARK: - Вкладка «Что послушать» / «Тренды» (Yandex Music Style)

struct TrendsExploreView: View {
    @State private var ym = YandexMusicService.shared
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared

    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var newAlbums: [YandexMusicService.YMAlbumItem] = []
    @State private var premiereTracks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = true
    @State private var selectedFilter: String = "top"
    @State private var selectedArtistStyleId: String = ""

    private var featuredAlbum: YandexMusicService.YMAlbumItem? {
        newAlbums.first
    }

    struct StyleArtist: Identifiable {
        let id: String
        let name: String
        let coverUrlString: String?
    }

    private var styleArtists: [StyleArtist] {
        var seen = Set<String>()
        var list: [StyleArtist] = []
        for track in chart {
            if let a = track.artists?.first, let id = a.id, !seen.contains(String(id)) {
                seen.insert(String(id))
                list.append(StyleArtist(id: String(id), name: a.name ?? "Артист", coverUrlString: track.coverUrlString))
            }
            if list.count >= 6 { break }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        headerView

                        categoriesRow

                        favoritesAndHistoryRow

                        if let featured = featuredAlbum {
                            artistRecommendsSection(featured)
                        }

                        newReleasesSection

                        moreDiscoveriesTop100Section

                        inStyleSection

                        premiereSection
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }
                .refreshable {
                    await load(force: true)
                }
            }
            .navigationBarHidden(true)
            .task {
                await load(force: false)
            }
        }
    }

    // MARK: - Header: Что послушать + Поиск

    private var headerView: some View {
        HStack {
            Spacer()
            Text("Что послушать")
                .font(AG.display(.title3, .bold))
                .foregroundStyle(.white)
            Spacer()

            NavigationLink {
                SearchCatalogView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(AG.glyph(.bold))
                    .foregroundStyle(AG.ink)
                    .frame(width: AG.tapTarget, height: AG.tapTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .accessibilityLabel("Поиск")
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Категории: Тренды, Книги, Детям, Подкасты

    private var categoriesRow: some View {
        HStack(spacing: 0) {
            // 1. Тренды (Розовая молния -> Топ 100)
            NavigationLink {
                Top100ChartView(title: "Тренды · Топ 100", tracks: chart)
            } label: {
                categoryItem(
                    title: "Тренды",
                    icon: "bolt.fill",
                    gradient: AG.Tile.pink
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            // 2. Книги (Синяя книга)
            NavigationLink {
                CategoryCatalogView(category: .books)
            } label: {
                categoryItem(
                    title: "Книги",
                    icon: "book.fill",
                    gradient: AG.Tile.blue,
                    hasDot: true
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            // 3. Детям (Оранжевый)
            NavigationLink {
                CategoryCatalogView(category: .kids)
            } label: {
                categoryItem(
                    title: "Детям",
                    icon: "teddybear.fill",
                    gradient: AG.Tile.orange
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            // 4. Подкасты (Зеленый микрофон)
            NavigationLink {
                CategoryCatalogView(category: .podcasts)
            } label: {
                categoryItem(
                    title: "Подкасты",
                    icon: "mic.fill",
                    gradient: AG.Tile.green
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
    }

    private func categoryItem(title: String, icon: String, gradient: [Color], hasDot: Bool = false) -> some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 58, height: 58)
                    .shadow(color: (gradient.first ?? .blue).opacity(0.40), radius: 10, x: 0, y: 5)

                Image(systemName: icon)
                    .font(AG.display(.title, .black))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 4) {
                if hasDot {
                    Circle()
                        .fill(AG.amber)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(AG.text(.footnote, .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Карточки: «Мне нравится» и «История»

    private var favoritesAndHistoryRow: some View {
        HStack(spacing: 12) {
            // Мне нравится
            NavigationLink {
                FavoritesListView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [AG.card, AG.coal], startPoint: .top, endPoint: .bottom))
                            .frame(width: 54, height: 54)
                        Image(systemName: "heart.fill")
                            .font(AG.display(.title2, .bold))
                            .foregroundStyle(AG.heart)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Мне\nнравится")
                            .font(AG.text(.footnote, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text("\(library.favorites.count) треков")
                            .font(AG.text(.caption2, .regular))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(GlassPressStyle())

            // История
            NavigationLink {
                HistoryListView()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: AG.Tile.graphite, startPoint: .top, endPoint: .bottom))
                            .frame(width: 54, height: 54)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(AG.display(.title2, .bold))
                            .foregroundStyle(AG.amber)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("История")
                            .font(AG.text(.footnote, .bold))
                            .foregroundStyle(.white)
                        Text("Недавно играло")
                            .font(AG.text(.caption2, .regular))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(GlassPressStyle())
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Артист рекомендует (Большой баннер)

    private func artistRecommendsSection(_ album: YandexMusicService.YMAlbumItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Артист рекомендует")
                .font(AG.display(.title2, .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ZStack(alignment: .bottomLeading) {
                RemoteArtwork(urlString: album.coverUrlString, corner: 24)
                    .frame(height: 280)
                    .overlay(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.3),
                                .init(color: Color.black.opacity(0.85), location: 0.95)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(album.displayTitle)
                            .font(AG.display(.title3, .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(album.artistName)
                            .font(AG.text(.subheadline, .medium))
                            .foregroundStyle(.white.opacity(0.80))
                    }

                    Spacer()

                    Button {
                        SonivoPlay.album(album)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(AG.text(.footnote, .bold))
                            Text("Слушать")
                                .font(AG.text(.subheadline, .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(.white))
                    }
                    .buttonStyle(GlassPressStyle())
                }
                .padding(18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Новые релизы >

    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Новые релизы")
                    .font(AG.display(.title2, .heavy))
                    .foregroundStyle(.white)

                Image(systemName: "chevron.right")
                    .font(AG.text(.subheadline, .bold))
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(newAlbums.prefix(12)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottomTrailing) {
                                    RemoteArtwork(urlString: album.coverUrlString, corner: 18)
                                        .frame(width: 156, height: 156)

                                    Button {
                                        SonivoPlay.album(album)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .font(AG.text(.subheadline, .bold))
                                            .foregroundStyle(.black)
                                            .frame(width: 36, height: 36)
                                            .background(Circle().fill(.white))
                                            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
                                    }
                                    .padding(8)
                                }

                                Text(album.displayTitle)
                                    .font(AG.text(.footnote, .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(.caption2, .regular))
                                    .foregroundStyle(.white.opacity(0.60))
                                    .lineLimit(1)
                            }
                            .frame(width: 156, alignment: .leading)
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Больше открытий (ТОП 100 по официальному API Яндекс Музыки)

    private var moreDiscoveriesTop100Section: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Больше открытий")
                    .font(AG.display(.title2, .heavy))
                    .foregroundStyle(.white)

                Spacer()

                // Фильтры: [ТОП] и [ПО ЯЗЫКУ]
                HStack(spacing: 6) {
                    Button {
                        selectedFilter = "top"
                    } label: {
                        Text("ТОП")
                            .font(AG.text(.caption2, .heavy))
                            .foregroundStyle(selectedFilter == "top" ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(selectedFilter == "top" ? AG.amber : Color.white.opacity(0.12))
                            )
                    }

                    Button {
                        selectedFilter = "lang"
                    } label: {
                        Text("ПО ЯЗЫКУ")
                            .font(AG.text(.caption2, .heavy))
                            .foregroundStyle(selectedFilter == "lang" ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(selectedFilter == "lang" ? AG.amber : Color.white.opacity(0.12))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)

            if isLoading && chart.isEmpty {
                ProgressView().tint(.yellow).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(chart.prefix(25).enumerated()), id: \.element.id) { index, item in
                        ChartRowView(rank: index + 1, item: item) {
                            SonivoPlay.track(item, in: chart)
                        }
                    }
                }

                // Ссылка на полный Топ-100
                NavigationLink {
                    Top100ChartView(title: "Топ 100 · Россия", tracks: chart)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                            .font(AG.text(.footnote, .bold))
                        Text("Показать все 100 треков чарта")
                            .font(AG.text(.subheadline, .bold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(AG.text(.caption2, .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AG.amber))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .buttonStyle(GlassPressStyle())
            }
        }
    }

    // MARK: - В стиле (Фильтр по артистам)

    private var inStyleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("В стиле")
                .font(AG.display(.title2, .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(styleArtists) { artist in
                        NavigationLink {
                            ArtistView(artistId: String(artist.id))
                        } label: {
                            HStack(spacing: 8) {
                                RemoteArtwork(urlString: artist.coverUrlString, corner: 16)
                                    .frame(width: 32, height: 32)
                                    .clipShape(Circle())

                                Text(artist.name)
                                    .font(AG.text(.footnote, .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Премьера > (Лучшие новые треки)

    private var premiereSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Text("Премьера")
                        .font(AG.display(.title2, .heavy))
                        .foregroundStyle(.white)

                    Image(systemName: "chevron.right")
                        .font(AG.text(.subheadline, .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            Text("Лучшие новые треки для вас")
                .font(AG.text(.footnote, .regular))
                .foregroundStyle(.white.opacity(0.60))
                .padding(.horizontal, 16)
                .padding(.top, -8)

            LazyVStack(spacing: 2) {
                let displayTracks = premiereTracks.isEmpty ? Array(chart.prefix(15)) : premiereTracks
                ForEach(Array(displayTracks.enumerated()), id: \.element.id) { index, item in
                    ChartRowView(rank: nil, item: item) {
                        SonivoPlay.track(item, in: displayTracks)
                    }
                }
            }
        }
    }

    private func load(force: Bool = false) async {
        isLoading = true
        do {
            chart = try await ym.getChart(force: force)
        } catch {
            chart = []
        }
        do {
            newAlbums = try await ym.getNewAlbums(force: force)
        } catch {
            newAlbums = []
        }
        premiereTracks = await ym.getNewTracks(limit: 20, force: force)
        isLoading = false
    }
}
