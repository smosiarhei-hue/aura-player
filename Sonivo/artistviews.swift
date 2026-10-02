import SwiftUI

// MARK: - Страница артиста (Apple Music 2026 Style)

struct ArtistView: View {
    let artistId: String
    @Environment(\.dismiss) private var dismiss
    @State private var ym = YandexMusicService.shared
    @State private var artist: YandexMusicService.YMArtistItem?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showingInfoSheet = false
    @State private var isFavorite = false
    @State private var showAllTopTracks = false
    @State private var scrollOffsetY: CGFloat = 0
    @State private var presentation = ActivePlayerPresentation.shared

    private let heroHeight: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            // Фон экрана
            SN.bg.ignoresSafeArea()

            if isLoading {
                skeletonLoadingView
            } else if let artist {
                mainContentView(artist)
            } else if let error {
                SonivoErrorState(message: error) { Task { await load() } }
                    .padding(.top, 120)
            }

            // Плавающий навигационный бар (Apple Music style)
            floatingNavBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingInfoSheet) {
            if let artist {
                ArtistInfoSheet(artist: artist, playWave: { playArtistWave(artist) })
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .task {
            loadFavoriteState()
            await load()
        }
    }

    // MARK: - Floating Navigation Bar

    private var navBarOpacity: Double {
        // Мягкое проявление заголовка при скролле вверх
        let threshold: CGFloat = 160
        guard scrollOffsetY < -40 else { return 0 }
        let progress = min(1.0, max(0.0, (-scrollOffsetY - 40) / threshold))
        return Double(progress)
    }

    private var floatingNavBar: some View {
        HStack(spacing: 12) {
            // Кнопка назад в полупрозрачном круге
            Button {
                Haptics.tap(.light)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))

            // Название артиста по центру (появляется при скролле)
            Text(artist?.name ?? "")
                .font(SN.display(.headline, .bold))
                .foregroundStyle(SN.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .opacity(navBarOpacity)

            // Правая капсула: Поделиться + Меню
            HStack(spacing: 4) {
                if let artist {
                    let shareURL = URL(string: "https://music.yandex.ru/artist/\(artist.id)") ?? URL(string: "https://music.yandex.ru")!
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                }

                Divider()
                    .frame(height: 16)
                    .background(Color.white.opacity(0.2))

                Menu {
                    if let artist {
                        Button {
                            playArtistWave(artist)
                        } label: {
                            Label("Волна артиста", systemImage: "dot.radiowaves.left.and.right")
                        }

                        Button {
                            toggleFavorite()
                        } label: {
                            Label(isFavorite ? "Удалить из избранного" : "Добавить в избранное",
                                  systemImage: isFavorite ? "star.slash" : "star")
                        }

                        if let first = artist.popularTracks.first {
                            Button {
                                SonivoPlay.track(first, in: artist.popularTracks)
                            } label: {
                                Label("Слушать популярное", systemImage: "play.fill")
                            }
                        }

                        Button {
                            showingInfoSheet = true
                        } label: {
                            Label("Об артисте", systemImage: "info.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 42)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .background {
            // Подложка навигационного бара при глубоком скролле
            Rectangle()
                .fill(SN.bg.opacity(navBarOpacity * 0.88))
                .background(.ultraThinMaterial.opacity(navBarOpacity))
                .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Main Scrollable Content

    private func mainContentView(_ artist: YandexMusicService.YMArtistItem) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Детектор скролла для параллакса и шапки
                GeometryReader { proxy in
                    let minY = proxy.frame(in: .global).minY
                    Color.clear
                        .preference(key: ArtistScrollOffsetKey.self, value: minY)
                }
                .frame(height: 0)

                // Hero-баннер артиста во всю ширину
                heroSection(artist)

                // Стек содержимого
                VStack(spacing: 24) {
                    // Карточка свежего / главного релиза
                    if let latest = sortedAlbums(artist.albums).first {
                        latestReleaseCard(latest)
                    }

                    // Секция популярных треков (Top Songs)
                    topSongsSection(artist)

                    // Секция альбомов
                    if !artist.albums.isEmpty {
                        albumsSection(artist)
                    }

                    // Похожие артисты
                    if !artist.similarArtists.isEmpty {
                        similarArtistsSection(artist)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 130)
            }
        }
        .coordinateSpace(name: "ArtistScrollSpace")
        .onPreferenceChange(ArtistScrollOffsetKey.self) { value in
            scrollOffsetY = value
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero Section (Apple Music 2026 Style)

    private func heroSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY
            let isPullingDown = minY > 0
            let effectiveHeight = heroHeight + (isPullingDown ? minY : 0)

            ZStack(alignment: .bottom) {
                // Фото артиста во всю ширину
                RemoteArtwork(urlString: artist.coverUrlString, corner: 0)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: effectiveHeight)
                    .clipped()
                    .offset(y: isPullingDown ? -minY : 0)

                // Многоступенчатый градиент растворения в темный фон
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.20), location: 0.0),
                        .init(color: .clear, location: 0.25),
                        .init(color: SN.bg.opacity(0.35), location: 0.60),
                        .init(color: SN.bg.opacity(0.85), location: 0.85),
                        .init(color: SN.bg, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: effectiveHeight)
                .offset(y: isPullingDown ? -minY : 0)

                // Имя артиста и панель действий
                VStack(spacing: 16) {
                    // Имя артиста (массивный жирный шрифт в верхнем регистре)
                    VStack(spacing: 6) {
                        Text(artist.name.uppercased())
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(Color.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.65), radius: 12, y: 4)

                        if !artist.subtitle.isEmpty {
                            Text(artist.subtitle)
                                .font(SN.text(.footnote, .semibold))
                                .foregroundStyle(Color.white.opacity(0.82))
                                .shadow(color: .black.opacity(0.50), radius: 6, y: 2)
                        }
                    }
                    .padding(.horizontal, 24)

                    // Фирменное трио действий (Info, Central Play, Star)
                    HStack(spacing: 24) {
                        // Кнопка (i) слева
                        Button {
                            Haptics.tap(.light)
                            showingInfoSheet = true
                        } label: {
                            Image(systemName: "info")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .frame(width: 52, height: 52)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.94))

                        // Большая белая круглая кнопка Play по центру
                        Button {
                            Haptics.tap(.heavy)
                            if let first = artist.popularTracks.first {
                                SonivoPlay.track(first, in: artist.popularTracks)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 72, height: 72)
                                    .shadow(color: .white.opacity(0.25), radius: 18, y: 6)
                                    .shadow(color: .black.opacity(0.40), radius: 10, y: 4)

                                Image(systemName: "play.fill")
                                    .font(.system(size: 28, weight: .black))
                                    .foregroundStyle(Color.black.opacity(0.92))
                                    .offset(x: 2)
                            }
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.94))

                        // Кнопка Star (Избранное) справа
                        Button {
                            toggleFavorite()
                        } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(isFavorite ? SN.amber : Color.white.opacity(0.92))
                                .frame(width: 52, height: 52)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(isFavorite ? SN.amber.opacity(0.4) : Color.white.opacity(0.20), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                                .scaleEffect(isFavorite ? 1.08 : 1.0)
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.94))
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: heroHeight)
    }

    // MARK: - Featured / Latest Release Card

    private func latestReleaseCard(_ album: YandexMusicService.YMAlbumItem) -> some View {
        NavigationLink {
            AlbumView(albumId: String(album.id), title: album.displayTitle)
        } label: {
            HStack(spacing: 14) {
                RemoteArtwork(urlString: album.coverUrlString, corner: 14)
                    .frame(width: 68, height: 68)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.40), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    if let year = album.year {
                        Text("\(year) · Релиз")
                            .font(SN.text(.caption2, .bold))
                            .foregroundStyle(SN.inkMuted)
                            .textCase(.uppercase)
                    } else {
                        Text("Свежий релиз")
                            .font(SN.text(.caption2, .bold))
                            .foregroundStyle(SN.inkMuted)
                            .textCase(.uppercase)
                    }

                    Text(album.displayTitle)
                        .font(SN.text(.subheadline, .bold))
                        .foregroundStyle(SN.ink)
                        .lineLimit(1)

                    Text(albumSubtitle(album))
                        .font(SN.text(.caption, .medium))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Кнопка добавления в медиатеку
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SN.ink)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))
    }

    private func albumSubtitle(_ album: YandexMusicService.YMAlbumItem) -> String {
        var parts: [String] = []
        if let count = album.trackCount {
            parts.append("\(count) " + (count == 1 ? "трек" : "треков"))
        }
        if let genre = album.genre, !genre.isEmpty {
            parts.append(genre.capitalized)
        }
        return parts.isEmpty ? "Альбом" : parts.joined(separator: " · ")
    }

    // MARK: - Top Songs Section

    private func topSongsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.popularTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // Заголовок Top Songs >
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            showAllTopTracks.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Top Songs")
                                .font(SN.display(.title3, .bold))
                                .foregroundStyle(SN.ink)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(SN.inkMuted)
                                .rotationEffect(.degrees(showAllTopTracks ? 90 : 0))
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                    }
                    .buttonStyle(.plain)

                    // Список треков
                    let visibleTracks = showAllTopTracks ? artist.popularTracks : Array(artist.popularTracks.prefix(5))
                    LazyVStack(spacing: 2) {
                        ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, item in
                            AppleTrackRowView(
                                item: item,
                                isPlaying: isItemPlaying(item),
                                onPlay: {
                                    SonivoPlay.track(item, in: artist.popularTracks)
                                },
                                onWave: {
                                    startTrackWave(item)
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func isItemPlaying(_ item: YandexMusicService.YMTrackItem) -> Bool {
        guard let current = presentation.displayTrack else { return false }
        return current.title == item.title && current.artist == item.artistName
    }

    private func startTrackWave(_ item: YandexMusicService.YMTrackItem) {
        let track = YandexMusicService.shared.convertToTrack(item)
        TrackWaveEngine.shared.startWave(from: track)
    }

    // MARK: - Albums Section

    private func albumsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Альбомы", accent: "и синглы")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(sortedAlbums(artist.albums).prefix(14)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            SonivoArtworkCard(
                                title: album.displayTitle,
                                subtitle: album.year.map(String.init),
                                width: 148
                            ) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                            }
                        }
                        .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Similar Artists Section

    private func similarArtistsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Похожие", accent: "артисты")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(artist.similarArtists.prefix(12)) { similar in
                        NavigationLink {
                            ArtistView(artistId: similar.id)
                        } label: {
                            VStack(spacing: 8) {
                                RemoteArtwork(urlString: similar.coverUrlString, corner: 999)
                                    .frame(width: 100, height: 100)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.30), radius: 8, y: 4)

                                Text(similar.name)
                                    .font(SN.text(.caption, .semibold))
                                    .foregroundStyle(SN.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: 108)
                        }
                        .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Skeleton Shimmer Loading State

    private var skeletonLoadingView: some View {
        VStack(spacing: 20) {
            // Skeleton Hero
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: heroHeight)
                .overlay(
                    VStack {
                        Spacer()
                        Circle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 72, height: 72)
                            .padding(.bottom, 24)
                    }
                )

            // Skeleton Release Card
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 90)
                .padding(.horizontal, 16)

            // Skeleton Track rows
            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .frame(height: 56)
                        .padding(.horizontal, 16)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: - Helpers & Data

    private func sortedAlbums(_ albums: [YandexMusicService.YMAlbumItem]) -> [YandexMusicService.YMAlbumItem] {
        albums.sorted {
            if $0.year != $1.year { return ($0.year ?? 0) > ($1.year ?? 0) }
            return $0.id > $1.id
        }
    }

    private func playArtistWave(_ artist: YandexMusicService.YMArtistItem) {
        Haptics.tap(.medium)
        Task {
            let tracks = await YandexMusicService.shared.buildArtistWave(artistId: artist.id, target: 45)
            guard let first = tracks.first else { return }
            PlaybackCommandRouter.shared.play(first, queue: tracks)
        }
    }

    private func loadFavoriteState() {
        let favorites = UserDefaults.standard.stringArray(forKey: "sonivo_favorite_artist_ids") ?? []
        isFavorite = favorites.contains(artistId)
    }

    private func toggleFavorite() {
        Haptics.tap(.medium)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            isFavorite.toggle()
        }
        var favorites = UserDefaults.standard.stringArray(forKey: "sonivo_favorite_artist_ids") ?? []
        if isFavorite {
            if !favorites.contains(artistId) { favorites.append(artistId) }
        } else {
            favorites.removeAll { $0 == artistId }
        }
        UserDefaults.standard.set(favorites, forKey: "sonivo_favorite_artist_ids")
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            artist = try await ym.getArtistFixed(artistId: artistId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Apple Track Row View (Matching Screenshot)

struct AppleTrackRowView: View {
    let item: YandexMusicService.YMTrackItem
    let isPlaying: Bool
    let onPlay: () -> Void
    let onWave: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                // Обложка трека с наложенным эквалайзером при игре
                ZStack {
                    RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                        .frame(width: 48, height: 48)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )

                    if isPlaying {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 48, height: 48)
                        LiveWaveEqualizer(isPlaying: true, color: SN.amber)
                    }
                }

                // Метаданные трека
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(isPlaying ? SN.amber : SN.ink)
                            .lineLimit(1)

                        if item.contentWarning == "explicit" {
                            Text("E")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }

                    Text(itemSubtitle)
                        .font(SN.text(.caption, .regular))
                        .foregroundStyle(isPlaying ? SN.amber.opacity(0.75) : SN.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Меню трека
                Menu {
                    Button {
                        SonivoPlay.download(item)
                    } label: {
                        Label("Скачать на iPhone", systemImage: "arrow.down.circle")
                    }

                    Button {
                        onWave()
                    } label: {
                        Label("Волна по треку", systemImage: "dot.radiowaves.left.and.right")
                    }

                    if let albums = item.albums, let firstAlbum = albums.first, let albumId = firstAlbum.id {
                        NavigationLink {
                            AlbumView(albumId: String(albumId), title: firstAlbum.title ?? "Альбом")
                        } label: {
                            Label("Перейти к альбому", systemImage: "opticaldisc")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SN.inkMuted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isPlaying ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))
    }

    private var itemSubtitle: String {
        var parts: [String] = []
        if let album = item.albums?.first?.title, !album.isEmpty {
            parts.append(album)
        } else {
            parts.append(item.artistName)
        }
        if let year = item.albums?.first?.year {
            parts.append(String(year))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Artist Info Sheet (Modal (i))

struct ArtistInfoSheet: View {
    let artist: YandexMusicService.YMArtistItem
    let playWave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SN.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Аватарка и заголовок
                    VStack(spacing: 12) {
                        RemoteArtwork(urlString: artist.coverUrlString, corner: 999)
                            .frame(width: 120, height: 120)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.40), radius: 14, y: 6)

                        Text(artist.name)
                            .font(SN.display(.title, .bold))
                            .foregroundStyle(SN.ink)

                        if !artist.genres.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(artist.genres.prefix(3), id: \.self) { genre in
                                    Text(genre.capitalized)
                                        .font(SN.text(.caption2, .semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.12), in: Capsule())
                                        .foregroundStyle(SN.ink)
                                }
                            }
                        }
                    }
                    .padding(.top, 24)

                    // Статистика
                    HStack(spacing: 12) {
                        statBox(title: "\(artist.popularTracks.count)", subtitle: "Популярных")
                        if let albumsCount = artist.counts?.directAlbums {
                            statBox(title: "\(albumsCount)", subtitle: "Релизов")
                        }
                        if let tracksCount = artist.counts?.tracks {
                            statBox(title: "\(tracksCount)", subtitle: "Всего треков")
                        }
                    }
                    .padding(.horizontal, 16)

                    // Кнопка включения Волны артиста
                    Button {
                        dismiss()
                        playWave()
                    } label: {
                        Label("Включить Волну артиста", systemImage: "dot.radiowaves.left.and.right")
                            .font(SN.text(.subheadline, .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.96))
                    .padding(.horizontal, 16)

                    Spacer(minLength: 20)
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func statBox(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(SN.text(.headline, .bold))
                .foregroundStyle(SN.ink)
            Text(subtitle)
                .font(SN.text(.caption2, .medium))
                .foregroundStyle(SN.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - PreferenceKey for Scroll Tracking

private struct ArtistScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Страница альбома (Apple Music 2026 Style)

struct AlbumView: View {
    let albumId: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var ym = YandexMusicService.shared
    @State private var album: YandexMusicService.YMAlbumItem?
    @State private var tracks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = true
    @State private var presentation = ActivePlayerPresentation.shared

    var body: some View {
        ZStack(alignment: .top) {
            SN.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    if isLoading {
                        SonivoLoadingState(title: "Загружаем альбом…")
                            .frame(minHeight: 400)
                    } else if let album {
                        heroSection(album)
                        tracksSection
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 120)
            }

            // Навигационная панель альбома
            albumNavBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var albumNavBar: some View {
        HStack {
            Button {
                Haptics.tap(.light)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))

            Spacer()

            if let album {
                let shareURL = URL(string: "https://music.yandex.ru/album/\(album.id)") ?? URL(string: "https://music.yandex.ru")!
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func heroSection(_ album: YandexMusicService.YMAlbumItem) -> some View {
        VStack(spacing: 16) {
            // Обложка с отражением и глубокой тенью
            RemoteArtwork(urlString: album.coverUrlString, corner: 22)
                .frame(width: 240, height: 240)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.60), radius: 24, y: 12)
                .padding(.top, 60)

            VStack(spacing: 6) {
                Text(album.displayTitle)
                    .font(SN.display(.title2, .bold))
                    .foregroundStyle(SN.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)

                artistLinks(album)

                HStack(spacing: 6) {
                    if let genre = album.genre, !genre.isEmpty {
                        Text(genre.capitalized)
                    }
                    if let year = album.year {
                        Text("· \(year)")
                    }
                }
                .font(SN.text(.caption, .medium))
                .foregroundStyle(SN.inkMuted)
            }

            // Кнопки воспроизведения и перемешивания
            if let first = tracks.first {
                HStack(spacing: 12) {
                    Button {
                        SonivoPlay.track(first, in: tracks)
                    } label: {
                        Label("Слушать", systemImage: "play.fill")
                            .font(SN.text(.subheadline, .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.96))

                    Button {
                        let shuffled = tracks.shuffled()
                        if let randomFirst = shuffled.first {
                            SonivoPlay.track(randomFirst, in: shuffled)
                        }
                    } label: {
                        Label("Перемешать", systemImage: "shuffle")
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(SN.ink)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.96))
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func artistLinks(_ album: YandexMusicService.YMAlbumItem) -> some View {
        let artists = (album.artists ?? []).compactMap { artist -> PlayerArtistLink? in
            guard let id = artist.id, let name = artist.name else { return nil }
            return PlayerArtistLink(id: String(id), name: name)
        }

        if artists.count == 1, let artist = artists.first {
            NavigationLink {
                ArtistView(artistId: artist.id)
            } label: {
                HStack(spacing: 4) {
                    Text(artist.name)
                        .font(SN.text(.headline, .semibold))
                        .foregroundStyle(SN.amber)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SN.amber.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
        } else if artists.count > 1 {
            Menu {
                ForEach(artists) { artist in
                    NavigationLink(artist.name) { ArtistView(artistId: artist.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(album.artistName)
                        .font(SN.text(.headline, .semibold))
                        .foregroundStyle(SN.amber)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SN.amber.opacity(0.7))
                }
            }
        } else {
            Text(album.artistName)
                .font(SN.text(.headline, .medium))
                .foregroundStyle(SN.inkMuted)
        }
    }

    private var tracksSection: some View {
        Group {
            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(tracks.count) треков")
                        .font(SN.text(.caption, .semibold))
                        .foregroundStyle(SN.inkMuted)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, item in
                            AppleAlbumTrackRow(
                                trackNumber: index + 1,
                                item: item,
                                isPlaying: isItemPlaying(item),
                                onPlay: {
                                    SonivoPlay.track(item, in: tracks)
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func isItemPlaying(_ item: YandexMusicService.YMTrackItem) -> Bool {
        guard let current = presentation.displayTrack else { return false }
        return current.title == item.title && current.artist == item.artistName
    }

    private func load() async {
        isLoading = true
        let id = Int(albumId) ?? 0
        album = ((try? await ym.fetchAlbums(ids: [id])) ?? []).first
        tracks = (try? await ym.getAlbumTracks(albumId: id)) ?? []
        isLoading = false
    }
}

// MARK: - Apple Album Track Row

struct AppleAlbumTrackRow: View {
    let trackNumber: Int
    let item: YandexMusicService.YMTrackItem
    let isPlaying: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 14) {
                // Номер трека или Live Equalizer
                ZStack {
                    if isPlaying {
                        LiveWaveEqualizer(isPlaying: true, color: SN.amber)
                    } else {
                        Text("\(trackNumber)")
                            .font(SN.text(.subheadline, .bold).monospacedDigit())
                            .foregroundStyle(SN.inkMuted)
                    }
                }
                .frame(width: 24, alignment: .center)

                // Название
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.title)
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(isPlaying ? SN.amber : SN.ink)
                            .lineLimit(1)

                        if item.contentWarning == "explicit" {
                            Text("E")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Color.white.opacity(0.85))
                        }
                    }

                    if let artistName = item.artists?.first?.name, !artistName.isEmpty {
                        Text(artistName)
                            .font(SN.text(.caption2))
                            .foregroundStyle(isPlaying ? SN.amber.opacity(0.75) : SN.inkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Длительность
                if let durationMs = item.durationMs {
                    let totalSeconds = durationMs / 1000
                    let min = totalSeconds / 60
                    let sec = totalSeconds % 60
                    Text(String(format: "%d:%02d", min, sec))
                        .font(SN.text(.caption, .regular).monospacedDigit())
                        .foregroundStyle(SN.inkMuted)
                }

                // Меню трека
                Menu {
                    Button {
                        SonivoPlay.download(item)
                    } label: {
                        Label("Скачать на iPhone", systemImage: "arrow.down.circle")
                    }

                    Button {
                        let track = YandexMusicService.shared.convertToTrack(item)
                        TrackWaveEngine.shared.startWave(from: track)
                    } label: {
                        Label("Волна по треку", systemImage: "dot.radiowaves.left.and.right")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SN.inkMuted)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPlaying ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))
    }
}
