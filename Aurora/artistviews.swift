import SwiftUI

// MARK: - Страница артиста

struct ArtistView: View {
    let artistId: String
    @State private var ym = YandexMusicService.shared
    @State private var artist: YandexMusicService.YMArtistItem?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ZStack {
            SonivoBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isLoading {
                        ProgressView().tint(AG.amber).frame(maxWidth: .infinity, minHeight: 400)
                    } else if let artist {
                        heroSection(artist)
                        popularTracksSection(artist)
                        albumsSection(artist)
                        similarArtistsSection(artist)
                    } else if let error {
                        errorView(error)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle(artist?.name ?? "Артист")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func heroSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(spacing: 0) {
            RemoteArtwork(urlString: artist.coverUrlString, corner: 0)
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .overlay {
                    LinearGradient(colors: [.clear, AG.bg.opacity(0.97)], startPoint: .center, endPoint: .bottom)
                }
                .clipped()

            VStack(spacing: 12) {
                Text(artist.name)
                    .font(AG.display(32, .heavy))
                    .foregroundStyle(AG.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                if !artist.subtitle.isEmpty {
                    Text(artist.subtitle)
                        .font(AG.text(13, .medium))
                        .foregroundStyle(AG.inkMuted)
                        .multilineTextAlignment(.center)
                }

                if let first = artist.popularTracks.first {
                    Button { SonivoPlay.track(first, in: artist.popularTracks) } label: {
                        Label("Слушать", systemImage: "play.fill")
                            .font(AG.text(14, .bold))
                            .foregroundStyle(.black.opacity(0.88))
                            .padding(.horizontal, 26)
                            .padding(.vertical, 13)
                            .background(AG.emberGradient, in: Capsule())
                    }
                    .buttonStyle(GlassPressStyle())
                    .pulsingGlow(AG.ember)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, -42)
        }
        .frame(maxWidth: .infinity)
    }

    private func popularTracksSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.popularTracks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SonivoHeader(title: "Популярные", accent: "треки").padding(.horizontal, 16)
                    LazyVStack(spacing: 2) {
                        ForEach(artist.popularTracks.prefix(20).enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }) { row in
                            ChartRowView(rank: row.rank, item: row.item) {
                                SonivoPlay.track(row.item, in: artist.popularTracks)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .riseIn(delay: 0.08)
            }
        }
    }

    private func albumsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.albums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SonivoHeader(title: "Альбомы", accent: "и синглы").padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(artist.albums.prefix(12)) { album in
                                NavigationLink {
                                    AlbumView(albumId: String(album.id), title: album.displayTitle)
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                                            .frame(width: 150, height: 150)
                                        Text(album.displayTitle)
                                            .font(AG.text(13, .semibold))
                                            .foregroundStyle(AG.ink)
                                            .lineLimit(1)
                                        if let year = album.year {
                                            Text(String(year)).font(AG.text(11, .regular)).foregroundStyle(AG.inkMuted)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                }
                                .buttonStyle(GlassPressStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .riseIn(delay: 0.14)
            }
        }
    }

    private func similarArtistsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.similarArtists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SonivoHeader(title: "Похожие", accent: "артисты").padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(artist.similarArtists.prefix(12)) { similar in
                                NavigationLink {
                                    ArtistView(artistId: similar.id)
                                } label: {
                                    VStack(spacing: 8) {
                                        RemoteArtwork(urlString: similar.coverUrlString, corner: 999)
                                            .frame(width: 110, height: 110)
                                        Text(similar.name)
                                            .font(AG.text(12, .semibold))
                                            .foregroundStyle(AG.ink)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(width: 110)
                                }
                                .buttonStyle(GlassPressStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .riseIn(delay: 0.20)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light)).foregroundStyle(AG.inkMuted)
            Text("Не удалось загрузить").font(AG.text(17, .semibold)).foregroundStyle(AG.ink)
            Text(message)
                .font(AG.text(13, .regular)).foregroundStyle(AG.inkMuted)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Повторить")
                    .font(AG.text(13, .bold)).foregroundStyle(.black.opacity(0.86))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(AG.emberGradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 60)
    }

    private func load() async {
        isLoading = true
        error = nil
        do { artist = try await ym.getArtistFixed(artistId: artistId) }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Страница альбома

struct AlbumView: View {
    let albumId: String
    let title: String
    @State private var ym = YandexMusicService.shared
    @State private var album: YandexMusicService.YMAlbumItem?
    @State private var tracks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            SonivoBackdrop()
            ScrollView {
                VStack(spacing: 24) {
                    if isLoading {
                        ProgressView().tint(AG.amber).frame(maxWidth: .infinity, minHeight: 400)
                    } else if let album {
                        heroSection(album)
                        tracksSection
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func heroSection(_ album: YandexMusicService.YMAlbumItem) -> some View {
        VStack(spacing: 16) {
            RemoteArtwork(urlString: album.coverUrlString, corner: 22)
                .frame(width: 232, height: 232)
                .shadow(color: .black.opacity(0.50), radius: 22, y: 12)
                .padding(.top, 18)
                .riseIn()

            VStack(spacing: 7) {
                Text(album.displayTitle)
                    .font(AG.display(25, .heavy))
                    .foregroundStyle(AG.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: 340)

                artistLinks(album)

                if let year = album.year {
                    Text(String(year)).font(AG.text(12, .regular)).foregroundStyle(AG.inkMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)

            if let first = tracks.first {
                Button { SonivoPlay.track(first, in: tracks) } label: {
                    Label("Слушать", systemImage: "play.fill")
                        .font(AG.text(14, .bold))
                        .foregroundStyle(.black.opacity(0.88))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(AG.emberGradient, in: Capsule())
                }
                .buttonStyle(GlassPressStyle())
                .pulsingGlow(AG.ember)
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
            NavigationLink { ArtistView(artistId: artist.id) } label: {
                Label(artist.name, systemImage: "chevron.right")
                    .labelStyle(ArtistTrailingChevronStyle())
                    .font(AG.text(15, .semibold))
                    .foregroundStyle(AG.amber)
            }
            .buttonStyle(.plain)
        } else if artists.count > 1 {
            Menu {
                ForEach(artists) { artist in
                    NavigationLink(artist.name) { ArtistView(artistId: artist.id) }
                }
            } label: {
                Label(album.artistName, systemImage: "chevron.down")
                    .font(AG.text(15, .semibold))
                    .foregroundStyle(AG.amber)
            }
        } else {
            Text(album.artistName).font(AG.text(15, .medium)).foregroundStyle(AG.inkMuted)
        }
    }

    private var tracksSection: some View {
        Group {
            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SonivoHeader(title: "Треки", subtitle: String(tracks.count) + " треков")
                        .padding(.horizontal, 16)
                    LazyVStack(spacing: 2) {
                        ForEach(tracks.enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }) { row in
                            ChartRowView(rank: row.rank, item: row.item) {
                                SonivoPlay.track(row.item, in: tracks)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .riseIn(delay: 0.10)
            }
        }
    }

    private func load() async {
        isLoading = true
        let id = Int(albumId) ?? 0
        album = ((try? await ym.fetchAlbums(ids: [id])) ?? []).first
        tracks = (try? await ym.getAlbumTracks(albumId: id)) ?? []
        isLoading = false
    }
}

private struct ArtistTrailingChevronStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.title
            configuration.icon.font(.system(size: 9, weight: .black))
        }
    }
}
