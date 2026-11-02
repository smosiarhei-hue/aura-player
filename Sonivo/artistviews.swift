import SwiftUI

// MARK: - Страница артиста (reference match: blur dissolve hero)

struct ArtistView: View {
    let artistId: String
    @Environment(\.dismiss) private var dismiss
    @State private var ym = YandexMusicService.shared
    @State private var artist: YandexMusicService.YMArtistItem?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showingInfoSheet = false
    @State private var isFavorite = false
    @State private var l10n = SonivoL10n.shared
    @State private var presentation = ActivePlayerPresentation.shared
    @State private var scrollOffsetY: CGFloat = 0
    @State private var heroAppeared = false
    private let heroHeaderHeight: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            SN.bg.ignoresSafeArea()

            if isLoading {
                skeletonLoadingView
            } else if let artist {
                mainContentView(artist)
            } else if let error {
                SonivoErrorState(message: error) { Task { await load() } }
                    .padding(.top, 120)
            }

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
            withAnimation(.easeOut(duration: 0.7)) { heroAppeared = true }
        }
    }

    // MARK: - Floating Navigation (separate glass circles)

    private var navBarOpacity: Double {
        let threshold: CGFloat = 160
        guard scrollOffsetY < -40 else { return 0 }
        let progress = min(CGFloat(1), max(CGFloat(0), (-scrollOffsetY - 40) / threshold))
        return Double(progress)
    }

    private var floatingNavBar: some View {
        HStack(spacing: 12) {
            glassCircleButton(systemName: "chevron.left") {
                Haptics.tap(.light)
                dismiss()
            }

            Text(artist?.name ?? "")
                .font(SN.display(.headline, .bold))
                .foregroundStyle(SN.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .opacity(navBarOpacity)

            if let artist {
                let shareURL = URL(string: "https://music.yandex.ru/artist/\(artist.id)")
                    ?? URL(string: "https://music.yandex.ru")!
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                }
            }

            Menu {
                if let artist {
                    Button { playArtistWave(artist) } label: {
                        Label(l10n.artistWave, systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button { toggleFavorite() } label: {
                        Label(isFavorite ? l10n.removeFromFavorites : l10n.addToFavorites,
                              systemImage: isFavorite ? "star.slash" : "star")
                    }
                    if let first = artist.popularTracks.first {
                        Button { SonivoPlay.track(first, in: artist.popularTracks) } label: {
                            Label(l10n.play, systemImage: "play.fill")
                        }
                    }
                    Button { showingInfoSheet = true } label: {
                        Label(l10n.aboutArtist, systemImage: "info.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .background {
            Rectangle()
                .fill(SN.bg.opacity(navBarOpacity * 0.9))
                .background(.ultraThinMaterial.opacity(navBarOpacity))
                .ignoresSafeArea(edges: .top)
        }
    }

    private func glassCircleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
        }
        .buttonStyle(TactileButtonStyle(scale: 0.92))
    }

    // MARK: - Main

    private func mainContentView(_ artist: YandexMusicService.YMArtistItem) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ArtistScrollOffsetKey.self,
                        value: proxy.frame(in: .global).minY
                    )
                }
                .frame(height: 0)

                heroSection(artist)

                // Name + action trio sit in the dissolve, pulled up into the photo
                artistHeaderContent(artist)
                    .offset(y: -56)
                    .padding(.bottom, -36)

                VStack(spacing: 22) {
                    if let latest = sortedAlbums(artist.albums).first {
                        latestReleaseCard(latest)
                    }

                    topSongsSection(artist)

                    playlistsSection(artist)

                    if !artist.albums.isEmpty {
                        albumsSection(artist)
                    }

                    if !artist.similarArtists.isEmpty {
                        similarArtistsSection(artist)
                    }
                }
                .padding(.bottom, 130)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(ArtistScrollOffsetKey.self) { scrollOffsetY = $0 }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero: sharp photo + bottom blur dissolve (reference)

    private func heroSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY
            let pull = max(0, minY)
            let height = heroHeaderHeight + pull
            let parallax = minY > 0 ? -minY : minY * 0.32
            let cover = artist.heroCoverUrlString ?? artist.coverUrlString

            ZStack(alignment: .bottom) {
                // Base photo — subject readable
                RemoteArtwork(urlString: cover, corner: 0)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: height)
                    .clipped()
                    .opacity(heroAppeared ? 1 : 0.7)
                    .offset(y: parallax)

                // Blurred twin, masked so only the lower half softens into the page
                RemoteArtwork(urlString: cover, corner: 0)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: height)
                    .scaleEffect(1.08)
                    .blur(radius: 28)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.28),
                                .init(color: .white.opacity(0.35), location: 0.52),
                                .init(color: .white.opacity(0.85), location: 0.72),
                                .init(color: .white, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .offset(y: parallax)

                // Soft dark vignette at top for nav contrast
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: height * 0.45)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: parallax)

                // Multi-stop dissolve into canvas — matches reference fade
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: SN.bg.opacity(0.25), location: 0.55),
                        .init(color: SN.bg.opacity(0.70), location: 0.75),
                        .init(color: SN.bg.opacity(0.92), location: 0.90),
                        .init(color: SN.bg, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: proxy.size.width, height: height)
                .offset(y: parallax)
            }
            .frame(width: proxy.size.width, height: height)
            .clipped()
            .offset(y: pull > 0 ? -pull : 0)
        }
        .frame(height: heroHeaderHeight)
    }

    // MARK: - Centered name + Info / Play / Star

    private func artistHeaderContent(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(spacing: 18) {
            Text(artist.name.uppercased())
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .shadow(color: .black.opacity(0.55), radius: 14, y: 4)
                .padding(.horizontal, 24)

            HStack(spacing: 28) {
                Button {
                    Haptics.tap(.light)
                    showingInfoSheet = true
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                }
                .buttonStyle(TactileButtonStyle(scale: 0.94))

                Button {
                    Haptics.tap(.heavy)
                    if let first = artist.popularTracks.first {
                        SonivoPlay.track(first, in: artist.popularTracks)
                    } else {
                        playArtistWave(artist)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 72, height: 72)
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                        Image(systemName: "play.fill")
                            .font(.system(size: 28, weight: .black))
                            .foregroundStyle(Color.black.opacity(0.92))
                            .offset(x: 2)
                    }
                }
                .buttonStyle(TactileButtonStyle(scale: 0.94))

                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isFavorite ? SN.amber : Color.white.opacity(0.92))
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle().strokeBorder(
                                isFavorite ? SN.amber.opacity(0.4) : Color.white.opacity(0.18),
                                lineWidth: 0.5
                            )
                        )
                        .scaleEffect(isFavorite ? 1.06 : 1.0)
                }
                .buttonStyle(TactileButtonStyle(scale: 0.94))
            }
        }
        .frame(maxWidth: .infinity)
        .opacity(heroAppeared ? 1 : 0)
        .offset(y: heroAppeared ? 0 : 12)
    }

    // MARK: - Latest release glass card

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

                VStack(alignment: .leading, spacing: 3) {
                    Text(releaseEyebrow(album))
                        .font(SN.text(.caption2, .bold))
                        .foregroundStyle(SN.inkMuted)
                        .textCase(.uppercase)

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

    private func releaseEyebrow(_ album: YandexMusicService.YMAlbumItem) -> String {
        if let year = album.year {
            return "\(String(format: "%d", year)) · \(l10n.releaseBadge)"
        }
        return l10n.latestRelease
    }

    private func albumSubtitle(_ album: YandexMusicService.YMAlbumItem) -> String {
        var parts: [String] = []
        if let count = album.trackCount {
            parts.append("\(count) " + (l10n.isRussian
                ? (count == 1 ? "песня" : (count < 5 ? "песни" : "песен"))
                : (count == 1 ? "Song" : "Songs")))
        }
        if let genre = album.genre, !genre.isEmpty {
            parts.append(genre.capitalized)
        }
        return parts.isEmpty ? (l10n.isRussian ? "Релиз" : "Release") : parts.joined(separator: " · ")
    }

    // MARK: - Top Songs

    private func topSongsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.popularTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink {
                        TopSongsView(artist: artist)
                    } label: {
                        HStack(spacing: 6) {
                            Text(l10n.topSongs)
                                .font(SN.display(.title3, .bold))
                                .foregroundStyle(SN.ink)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(SN.inkMuted)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)

                    LazyVStack(spacing: 2) {
                        ForEach(artist.popularTracks.prefix(5)) { item in
                            AppleTrackRowView(
                                item: item,
                                isPlaying: isItemPlaying(item),
                                onPlay: { SonivoPlay.track(item, in: artist.popularTracks) },
                                onWave: { startTrackWave(item) }
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Playlists

    private enum ArtistSpotlight: Identifiable {
        case wave
        case popular
        case album(YandexMusicService.YMAlbumItem)

        var id: String {
            switch self {
            case .wave: return "wave"
            case .popular: return "popular"
            case .album(let album): return "album-\(album.id)"
            }
        }
    }

    private func playlistsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        let cards = artistSpotlights(artist)
        return Group {
            if !cards.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.playlists)
                        .font(SN.display(.title3, .bold))
                        .foregroundStyle(SN.ink)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(cards) { card in
                                Button {
                                    Haptics.tap(.medium)
                                    playSpotlight(card, artist: artist)
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ZStack(alignment: .bottomLeading) {
                                            RemoteArtwork(urlString: spotlightCover(card, artist: artist), corner: 18)
                                                .frame(width: 148, height: 148)
                                                .overlay(
                                                    LinearGradient(
                                                        colors: [.clear, .black.opacity(0.5)],
                                                        startPoint: .center,
                                                        endPoint: .bottom
                                                    )
                                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                                                )

                                            Image(systemName: spotlightSymbol(card))
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(12)
                                        }

                                        Text(spotlightTitle(card))
                                            .font(SN.text(.subheadline, .semibold))
                                            .foregroundStyle(SN.ink)
                                            .lineLimit(2)
                                            .frame(width: 148, alignment: .leading)
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
        }
    }

    private func artistSpotlights(_ artist: YandexMusicService.YMArtistItem) -> [ArtistSpotlight] {
        var cards: [ArtistSpotlight] = [.wave]
        if !artist.popularTracks.isEmpty { cards.append(.popular) }
        cards.append(contentsOf: sortedAlbums(artist.albums).dropFirst().prefix(4).map(ArtistSpotlight.album))
        return Array(cards.prefix(8))
    }

    private func spotlightTitle(_ card: ArtistSpotlight) -> String {
        switch card {
        case .wave: return l10n.artistWave
        case .popular: return l10n.topSongs
        case .album(let album): return album.displayTitle
        }
    }

    private func spotlightCover(_ card: ArtistSpotlight, artist: YandexMusicService.YMArtistItem) -> String? {
        switch card {
        case .wave: return artist.coverUrlString
        case .popular: return artist.popularTracks.first?.coverUrlString ?? artist.coverUrlString
        case .album(let album): return album.coverUrlString
        }
    }

    private func spotlightSymbol(_ card: ArtistSpotlight) -> String {
        switch card {
        case .wave: return "dot.radiowaves.left.and.right"
        case .popular: return "chart.bar.fill"
        case .album: return "opticaldisc"
        }
    }

    private func playSpotlight(_ card: ArtistSpotlight, artist: YandexMusicService.YMArtistItem) {
        switch card {
        case .wave:
            playArtistWave(artist)
        case .popular:
            if let first = artist.popularTracks.first {
                SonivoPlay.track(first, in: artist.popularTracks)
            }
        case .album(let album):
            let related = artist.popularTracks.filter { track in
                track.albums?.contains(where: { $0.id == album.id }) == true
            }
            if let first = related.first {
                SonivoPlay.track(first, in: related)
            } else if let first = artist.popularTracks.first {
                SonivoPlay.track(first, in: artist.popularTracks)
            }
        }
    }

    // MARK: - Albums

    private func albumsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.albumsAndSingles)
                .font(SN.display(.title3, .bold))
                .foregroundStyle(SN.ink)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(sortedAlbums(artist.albums).prefix(14)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                                    .frame(width: 148, height: 148)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                                    )

                                Text(album.displayTitle)
                                    .font(SN.text(.subheadline, .semibold))
                                    .foregroundStyle(SN.ink)
                                    .lineLimit(2)
                                    .frame(width: 148, alignment: .leading)

                                if let year = album.year {
                                    Text(String(year))
                                        .font(SN.text(.caption, .medium))
                                        .foregroundStyle(SN.inkMuted)
                                }
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

    // MARK: - Similar

    private func similarArtistsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.similarArtists)
                .font(SN.display(.title3, .bold))
                .foregroundStyle(SN.ink)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(artist.similarArtists.prefix(12)) { similar in
                        NavigationLink {
                            ArtistView(artistId: similar.id)
                        } label: {
                            VStack(spacing: 10) {
                                RemoteArtwork(urlString: similar.coverUrlString, corner: 999)
                                    .frame(width: 96, height: 96)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))

                                Text(similar.name)
                                    .font(SN.text(.caption, .semibold))
                                    .foregroundStyle(SN.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: 104)
                        }
                        .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Skeleton

    private var skeletonLoadingView: some View {
        VStack(spacing: 20) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: heroHeaderHeight)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, SN.bg], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                }

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(height: 96)
                .padding(.horizontal, 16)

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

    // MARK: - Helpers

    private func isItemPlaying(_ item: YandexMusicService.YMTrackItem) -> Bool {
        guard let current = presentation.displayTrack else { return false }
        return current.title == item.title && current.artist == item.artistName
    }

    private func startTrackWave(_ item: YandexMusicService.YMTrackItem) {
        let track = YandexMusicService.shared.convertToTrack(item)
        playTrackWave(from: track)
    }

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
    var rank: Int? = nil
    let isPlaying: Bool
    let onPlay: () -> Void
    let onWave: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if let rank {
                    Text("\(rank)")
                        .font(SN.text(.subheadline, .bold))
                        .foregroundStyle(SN.inkMuted)
                        .frame(width: 22, alignment: .trailing)
                }

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
                    Text(item.title)
                        .font(SN.text(.subheadline, .semibold))
                        .foregroundStyle(isPlaying ? SN.amber : SN.ink)
                        .lineLimit(1)

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
    @State private var similarArtists: [YandexMusicService.YMArtistItem.YMArtistBrief] = []
    @State private var isLoading = true
    @State private var presentation = ActivePlayerPresentation.shared
    @State private var l10n = SonivoL10n.shared

    var body: some View {
        ZStack(alignment: .top) {
            SN.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    if isLoading {
                        SonivoLoadingState(title: l10n.isRussian ? "Загружаем альбом…" : "Loading album…")
                            .frame(minHeight: 400)
                    } else if let album {
                        heroSection(album)
                        tracksSection
                        metaAndCopyrightSection(album)
                        if !similarArtists.isEmpty {
                            similarArtistsSection
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 130)
            }
            .scrollBounceBehavior(.basedOnSize)

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
                .frame(width: 230, height: 230)
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

                // Подпись: "Сингл · 2026 · 1 песня"
                Text(albumTypeSubtitle(album))
                    .font(SN.text(.caption, .medium))
                    .foregroundStyle(SN.inkMuted)
            }

            // Кнопки "Воспроизвести" и "Перемешать" (Apple Music 2026 style)
            if let first = tracks.first {
                HStack(spacing: 12) {
                    Button {
                        SonivoPlay.track(first, in: tracks)
                    } label: {
                        Label(l10n.play, systemImage: "play.fill")
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
                        Label(l10n.shuffle, systemImage: "shuffle")
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(SN.ink)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.96))
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func albumTypeSubtitle(_ album: YandexMusicService.YMAlbumItem) -> String {
        var parts: [String] = []
        let count = tracks.count
        if count == 1 {
            parts.append(l10n.single)
        } else {
            parts.append(l10n.album)
        }
        if let year = album.year {
            parts.append(String(format: "%d", year))
        }
        if count > 0 {
            parts.append(l10n.songsCount(count))
        }
        return parts.joined(separator: " · ")
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
                VStack(alignment: .leading, spacing: 2) {
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

    private func metaAndCopyrightSection(_ album: YandexMusicService.YMAlbumItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let year = album.year ?? 2026
            let totalSec = tracks.reduce(0) { $0 + $1.durationMs } / 1000
            let minutes = totalSec / 60
            Text("\(String(format: "%d", year)) · \(l10n.songsCount(tracks.count)), \(l10n.minutesText(minutes))")
                .font(SN.text(.footnote, .semibold))
                .foregroundStyle(SN.inkMuted)

            Text("℗ \(String(format: "%d", year)) \(album.artistName)")
                .font(SN.text(.caption2, .regular))
                .foregroundStyle(SN.inkMuted.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(l10n.similarArtists)
                    .font(SN.display(.title3, .bold))
                    .foregroundStyle(SN.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SN.inkMuted)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(similarArtists.prefix(8)) { similar in
                        NavigationLink {
                            ArtistView(artistId: similar.id)
                        } label: {
                            VStack(spacing: 8) {
                                RemoteArtwork(urlString: similar.coverUrlString, corner: 999)
                                    .frame(width: 86, height: 86)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                                Text(similar.name)
                                    .font(SN.text(.caption, .semibold))
                                    .foregroundStyle(SN.ink)
                                    .lineLimit(1)
                            }
                            .frame(width: 90)
                        }
                        .buttonStyle(CardPressStyle(scale: 0.96, haptic: true))
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 16)
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
        if let artistId = album?.artists?.first?.id {
            if let artistObj = try? await ym.getArtistFixed(artistId: String(artistId)) {
                similarArtists = artistObj.similarArtists
            }
        }
        isLoading = false
    }
}

// MARK: - Выделенный экран Top Songs (Apple Music 2026 Style)

struct TopSongsView: View {
    let artist: YandexMusicService.YMArtistItem
    @Environment(\.dismiss) private var dismiss
    @State private var presentation = ActivePlayerPresentation.shared
    @State private var l10n = SonivoL10n.shared

    var body: some View {
        ZStack(alignment: .top) {
            SN.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(artist.popularTracks.enumerated()), id: \.element.id) { index, item in
                        AppleTrackRowView(
                            item: item,
                            isPlaying: isItemPlaying(item),
                            onPlay: {
                                SonivoPlay.track(item, in: artist.popularTracks)
                            },
                            onWave: {
                                let track = YandexMusicService.shared.convertToTrack(item)
                                playTrackWave(from: track)
                            }
                        )
                    }
                }
                .padding(.top, 64)
                .padding(.bottom, 130)
            }
            .scrollBounceBehavior(.basedOnSize)

            // Навигационный бар с заголовком
            HStack(spacing: 12) {
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

                Text(l10n.topSongs)
                    .font(SN.display(.headline, .bold))
                    .foregroundStyle(SN.ink)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .background {
                Rectangle()
                    .fill(SN.bg.opacity(0.85))
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea(edges: .top)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func isItemPlaying(_ item: YandexMusicService.YMTrackItem) -> Bool {
        guard let current = presentation.displayTrack else { return false }
        return current.title == item.title && current.artist == item.artistName
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
                    Text(item.title)
                        .font(SN.text(.subheadline, .semibold))
                        .foregroundStyle(isPlaying ? SN.amber : SN.ink)
                        .lineLimit(1)

                    if let artistName = item.artists?.first?.name, !artistName.isEmpty {
                        Text(artistName)
                            .font(SN.text(.caption2))
                            .foregroundStyle(isPlaying ? SN.amber.opacity(0.75) : SN.inkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Длительность
                if item.durationMs > 0 {
                    let totalSeconds = item.durationMs / 1000
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
                        playTrackWave(from: track)
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

// MARK: - Play Track Wave Helper

@MainActor
private func playTrackWave(from track: Track) {
    Haptics.tap(.medium)
    Task {
        let tracks = await YandexMusicService.shared.buildTrackWave(from: track, target: 45)
        guard let first = tracks.first else { return }
        PlaybackCommandRouter.shared.play(first, queue: tracks)
        MoodRadioEngine.shared.activateYandexTrackWave(tracks: tracks)
    }
}

