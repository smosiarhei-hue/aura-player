import SwiftUI

// MARK: - Страница артиста

struct ArtistView: View {
    let artistId: String
    @StateObject private var ym = YandexMusicService.shared
    @State private var artist: YandexMusicService.YMArtistItem?
    @State private var isLoading = true
    @State private var error: String? = nil

    var body: some View {
        ZStack {
            SonivoBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isLoading {
                        ProgressView()
                            .tint(AG.amber)
                            .frame(maxWidth: .infinity, minHeight: 400)
                    } else if let artist {
                        heroSection(artist)
                        popularTracksSection(artist)
                        albumsSection(artist)
                        similarArtistsSection(artist)
                    } else if let error {
                        errorView(error)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle(artist?.name ?? "Артист")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    // MARK: Hero

    private func heroSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        VStack(spacing: 0) {
            RemoteArtwork(urlString: artist.coverUrlString, corner: 0)
                .frame(height: 320)
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), AG.bg.opacity(0.95)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
                .clipped()

            VStack(spacing: 12) {
                Text(artist.name)
                    .font(AG.display(32, .heavy))
                    .foregroundStyle(AG.ink)
                    .multilineTextAlignment(.center)

                if !artist.subtitle.isEmpty {
                    Text(artist.subtitle)
                        .font(AG.text(13, .medium))
                        .foregroundStyle(AG.inkMuted)
                }

                if !artist.popularTracks.isEmpty {
                    Button {
                        SonivoPlay.track(artist.popularTracks[0], in: artist.popularTracks)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .black))
                            Text("Слушать")
                                .font(AG.text(14, .bold))
                        }
                        .foregroundStyle(Color.black.opacity(0.88))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(AG.emberGradient))
                    }
                    .buttonStyle(GlassPressStyle())
                    .pulsingGlow(AG.ember)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, -40)
        }
    }

    // MARK: Популярные треки

    private func popularTracksSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.popularTracks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SonivoHeader(title: "Популярные", accent: "треки")
                        .padding(.horizontal, 16)

                    LazyVStack(spacing: 2) {
                        ForEach(artist.popularTracks.prefix(20).enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }) { row in
                            ChartRowView(rank: row.rank, item: row.item) {
                                SonivoPlay.track(row.item, in: artist.popularTracks)
                            }
                        }
                    }
                }
                .riseIn(delay: 0.08)
            }
        }
    }

    // MARK: Альбомы

    private func albumsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.albums.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SonivoHeader(title: "Альбомы", accent: "и синглы")
                        .padding(.horizontal, 16)

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
                                            Text(String(year))
                                                .font(AG.text(11, .regular))
                                                .foregroundStyle(AG.inkMuted)
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
                .riseIn(delay: 0.14)
            }
        }
    }

    // MARK: Похожие артисты

    private func similarArtistsSection(_ artist: YandexMusicService.YMArtistItem) -> some View {
        Group {
            if !artist.similarArtists.isEmpty {
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
                .riseIn(delay: 0.20)
            }
        }
    }

    // MARK: Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(AG.inkMuted)

            Text("Не удалось загрузить")
                .font(AG.text(17, .semibold))
                .foregroundStyle(AG.ink)

            Text(message)
                .font(AG.text(13, .regular))
                .foregroundStyle(AG.inkMuted)
                .multilineTextAlignment(.center)

            Button {
                Task { await load() }
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
        .padding(.horizontal, 32)
        .padding(.vertical, 60)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            artist = try await ym.getArtist(artistId: artistId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Страница альбома

struct AlbumView: View {
    let albumId: String
    let title: String
    @StateObject private var ym = YandexMusicService.shared
    @State private var album: YandexMusicService.YMAlbumItem?
    @State private var tracks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            SonivoBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isLoading {
                        ProgressView()
                            .tint(AG.amber)
                            .frame(maxWidth: .infinity, minHeight: 400)
                    } else if let album {
                        heroSection(album)
                        tracksSection
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func heroSection(_ album: YandexMusicService.YMAlbumItem) -> some View {
        VStack(spacing: 16) {
            RemoteArtwork(urlString: album.coverUrlString, corner: 20)
                .frame(width: 220, height: 220)
                .shadow(color: Color.black.opacity(0.5), radius: 20, y: 10)
                .padding(.top, 20)
                .riseIn()

            VStack(spacing: 6) {
                Text(album.displayTitle)
                    .font(AG.display(24, .heavy))
                    .foregroundStyle(AG.ink)
                    .multilineTextAlignment(.center)

                if let artist = album.artists?.first, let aid = artist.id, let name = artist.name {
                    NavigationLink {
                        ArtistView(artistId: String(aid))
                    } label: {
                        HStack(spacing: 5) {
                            Text(name)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .black))
                        }
                        .font(AG.text(15, .medium))
                        .foregroundStyle(AG.amber.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(album.artistName)
                        .font(AG.text(15, .medium))
                        .foregroundStyle(AG.inkMuted)
                }

                if let year = album.year {
                    Text(String(year))
                        .font(AG.text(12, .regular))
                        .foregroundStyle(AG.inkMuted)
                }
            }
            .padding(.horizontal, 20)

            if !tracks.isEmpty {
                Button {
                    SonivoPlay.track(tracks[0], in: tracks)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .black))
                        Text("Слушать")
                            .font(AG.text(14, .bold))
                    }
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(AG.emberGradient))
                }
                .buttonStyle(GlassPressStyle())
                .pulsingGlow(AG.ember)
            }
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
                .riseIn(delay: 0.10)
            }
        }
    }

    private func load() async {
        isLoading = true
        let albumIdInt = Int(albumId) ?? 0
        album = try? await ym.fetchAlbums(ids: [albumIdInt]).first
        tracks = (try? await ym.getAlbumTracks(albumId: albumIdInt)) ?? []
        isLoading = false
    }
}
