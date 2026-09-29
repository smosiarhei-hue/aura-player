import SwiftUI

// MARK: - 1. Favorites List View («Мне нравится»)

struct FavoritesListView: View {
    @State private var library = LibraryStore.shared
    @State private var player = ActivePlayerPresentation()

    var body: some View {
        ZStack {
            SonivoBackdrop()

            if library.favorites.isEmpty {
                SonivoEmptyState(
                    systemImage: "heart.slash",
                    title: "В избранном пока ничего нет",
                    message: "Нажимайте на сердечко в плеере или треках, чтобы собирать любимую музыку здесь."
                )
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        // Header Action Banner
                        HStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(LinearGradient(colors: SN.Tile.red, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 84, height: 84)
                                    .shadow(color: SN.heart.opacity(0.40), radius: 12, y: 6)

                                Image(systemName: "heart.fill")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundStyle(SN.ink)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Мне нравится")
                                    .font(SN.display(.title2, .bold))
                                    .foregroundStyle(SN.ink)
                                Text("\(library.favorites.count) треков в коллекции")
                                    .font(SN.text(.footnote, .medium))
                                    .foregroundStyle(SN.inkMuted)

                                HStack(spacing: 10) {
                                    Button {
                                        if let first = library.favorites.first {
                                            PlaybackCommandRouter.shared.play(first, queue: library.favorites)
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "play.fill")
                                                .font(SN.text(.caption, .bold))
                                            Text("Слушать")
                                                .font(SN.text(.footnote, .bold))
                                        }
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(.white))
                                    }
                                    .buttonStyle(GlassPressStyle())
                                    .accessibilityLabel("Слушать избранное")

                                    Button {
                                        let shuffled = library.favorites.shuffled()
                                        if let first = shuffled.first {
                                            PlaybackCommandRouter.shared.play(first, queue: shuffled)
                                        }
                                    } label: {
                                        Image(systemName: "shuffle")
                                            .font(SN.text(.subheadline, .bold))
                                            .foregroundStyle(SN.ink)
                                            .frame(width: SN.tapTarget, height: SN.tapTarget)
                                            .background(Circle().fill(SN.ink.opacity(0.12)))
                                    }
                                    .buttonStyle(GlassPressStyle())
                                    .accessibilityLabel("Перемешать избранное")
                                }
                                .padding(.top, 4)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                        // Track List
                        LazyVStack(spacing: 4) {
                            ForEach(library.favorites) { track in
                                HStack(spacing: 8) {
                                    Button {
                                        PlaybackCommandRouter.shared.play(track, queue: library.favorites)
                                    } label: {
                                        HStack(spacing: 12) {
                                            SmallArtwork(track: track, size: 46)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(track.title)
                                                    .font(SN.text(.subheadline, .semibold))
                                                    .foregroundStyle(player.displayTrack?.id == track.id ? SN.heart : SN.ink)
                                                    .lineLimit(1)
                                                Text(track.artist)
                                                    .font(SN.text(.footnote))
                                                    .foregroundStyle(SN.inkMuted)
                                                    .lineLimit(1)
                                            }

                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        library.toggleFavorite(track)
                                    } label: {
                                        Image(systemName: "heart.fill")
                                            .font(SN.text(.callout, .semibold))
                                            .foregroundStyle(SN.heart)
                                            .frame(width: SN.tapTarget, height: SN.tapTarget)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Убрать из избранного")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(player.displayTrack?.id == track.id ? SN.ink.opacity(0.06) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .padding(.bottom, 96)
                }
            }
        }
        .navigationTitle("Мне нравится")
        .navigationBarTitleDisplayMode(.inline)
        .task { await player.observeTimeline() }
    }
}

// MARK: - 2. History List View («История»)

struct HistoryListView: View {
    @State private var ym = YandexMusicService.shared
    @State private var library = LibraryStore.shared
    @State private var player = ActivePlayerPresentation()

    private var historyTracks: [Track] {
        var result: [Track] = []
        var seen = Set<UUID>()

        for ymId in ym.recentYmIDs {
            if let tr = library.tracks.first(where: { PlayerCore.yandexTrackID(from: $0) == ymId }), !seen.contains(tr.id) {
                result.append(tr)
                seen.insert(tr.id)
            } else if let cached = ym.chartCache.first(where: { $0.id == ymId }) {
                let tr = ym.convertToTrack(cached)
                if !seen.contains(tr.id) {
                    result.append(tr)
                    seen.insert(tr.id)
                }
            }
        }

        for tr in library.tracks.suffix(30).reversed() where !seen.contains(tr.id) {
            result.append(tr)
            seen.insert(tr.id)
        }

        return result
    }

    var body: some View {
        ZStack {
            SonivoBackdrop()

            if historyTracks.isEmpty {
                SonivoEmptyState(
                    systemImage: "clock.arrow.circlepath",
                    title: "История прослушиваний пуста",
                    message: "Здесь будут сохраняться все треки, которые вы включали."
                )
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("История прослушиваний")
                                    .font(SN.display(.title2, .bold))
                                                    .foregroundStyle(SN.ink)
                                Text("\(historyTracks.count) последних треков")
                                    .font(SN.text(.footnote))
                                                    .foregroundStyle(SN.inkMuted)
                            }
                            Spacer()

                            Button {
                                ym.clearMemory()
                            } label: {
                                Text("Очистить")
                                    .font(SN.text(.footnote, .semibold))
                                    .foregroundStyle(SN.inkMuted)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(SN.ink.opacity(0.10)))
                            }
                            .buttonStyle(GlassPressStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                        LazyVStack(spacing: 4) {
                            ForEach(historyTracks) { track in
                                Button {
                                    PlaybackCommandRouter.shared.play(track, queue: historyTracks)
                                } label: {
                                    HStack(spacing: 12) {
                                        SmallArtwork(track: track, size: 46)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title)
                                                .font(SN.text(.subheadline, .semibold))
                                                .foregroundStyle(player.displayTrack?.id == track.id ? SN.amber : .white)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(SN.text(.footnote))
                                                .foregroundStyle(SN.inkMuted)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 24))
                                                .foregroundStyle(SN.inkFaint)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(player.displayTrack?.id == track.id ? SN.ink.opacity(0.06) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.bottom, 96)
                }
            }
        }
        .navigationTitle("История")
        .navigationBarTitleDisplayMode(.inline)
        .task { await player.observeTimeline() }
    }
}

// MARK: - 3. Category Catalog View (Книги, Детям, Подкасты)

enum TrendsCatalogCategory: String, Identifiable {
    case books = "Книги"
    case kids = "Детям"
    case podcasts = "Подкасты"

    var id: String { rawValue }

    var searchQuery: String {
        switch self {
        case .books: return "Аудиокнига"
        case .kids: return "Детские сказки"
        case .podcasts: return "Подкаст"
        }
    }

    var icon: String {
        switch self {
        case .books: return "book.fill"
        case .kids: return "teddybear.fill"
        case .podcasts: return "mic.fill"
        }
    }

    var gradient: [Color] {
        switch self {
        case .books: return SN.Tile.blue
        case .kids: return SN.Tile.orange
        case .podcasts: return SN.Tile.green
        }
    }

    var subtitle: String {
        switch self {
        case .books: return "Лучшие аудиокниги и литературные бестселлеры"
        case .kids: return "Сказки на ночь, детские песни и аудиоспектакли"
        case .podcasts: return "Популярные разговорные выпуски, наука и истории"
        }
    }
}

struct CategoryCatalogView: View {
    let category: TrendsCatalogCategory
    @State private var player = ActivePlayerPresentation()
    @State private var ym = YandexMusicService.shared
    @State private var results = YandexMusicService.GlobalSearchResults()
    @State private var isLoading = true

    var body: some View {
        ZStack {
            SonivoBackdrop()

            ScrollView {
                VStack(spacing: 20) {
                    // Category Hero Banner
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: category.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: category.gradient.first?.opacity(0.35) ?? .clear, radius: 14, y: 7)

                        HStack(alignment: .bottom, spacing: 16) {
                            Image(systemName: category.icon)
                                .font(.system(size: 48, weight: .black))
                                .foregroundStyle(SN.ink)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(category.rawValue)
                                    .font(SN.display(.title, .black))
                                    .foregroundStyle(SN.ink)
                                Text(category.subtitle)
                                    .font(SN.text(.footnote, .medium))
                                    .foregroundStyle(SN.inkMuted)
                                    .lineLimit(2)
                            }
                        }
                        .padding(20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if isLoading {
                        SonivoLoadingState(title: "Загружаем подборку…")
                    } else if results.tracks.isEmpty && results.albums.isEmpty {
                        SonivoEmptyState(
                            systemImage: category.icon,
                            title: "Ничего не найдено",
                            message: "Попробуйте обновить страницу или выбрать другой раздел."
                        )
                    } else {
                        // Play All Button
                        if !results.tracks.isEmpty {
                            HStack {
                                Button {
                                    if let first = results.tracks.first {
                                        SonivoPlay.track(first, in: results.tracks)
                                    }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "play.fill")
                                            .font(SN.text(.caption, .bold))
                                        Text("Слушать подборку")
                                            .font(SN.text(.subheadline, .bold))
                                    }
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(.white))
                                }
                                .buttonStyle(GlassPressStyle())

                                Spacer()

                                Text("\(results.tracks.count) выпусков")
                                    .font(SN.text(.footnote, .medium))
                                    .foregroundStyle(SN.inkMuted)
                            }
                            .padding(.horizontal, 16)
                        }

                        // Albums / Collections Section
                        if !results.albums.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Коллекции и циклы")
                                    .font(SN.text(.headline, .bold))
                                    .foregroundStyle(SN.ink)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(results.albums) { album in
                                            Button {
                                                SonivoPlay.album(album)
                                            } label: {
                                                SonivoArtworkCard(title: album.displayTitle, subtitle: album.artistName, width: 130) {
                                                    RemoteArtwork(urlString: album.coverUrlString, corner: 14)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }

                        // Tracks / Audiobooks List
                        if !results.tracks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Выпуски")
                                    .font(SN.text(.headline, .bold))
                                    .foregroundStyle(SN.ink)
                                    .padding(.horizontal, 16)

                                LazyVStack(spacing: 4) {
                                    ForEach(results.tracks) { item in
                                        Button {
                                            SonivoPlay.track(item, in: results.tracks)
                                        } label: {
                                            HStack(spacing: 12) {
                                                RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                                                    .frame(width: 46, height: 46)

                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(item.title)
                                                        .font(SN.text(.subheadline, .semibold))
                                                        .foregroundStyle(player.displayTrack?.title == item.title ? (category.gradient.first ?? .white) : .white)
                                                        .lineLimit(1)
                                                    Text(item.artists?.first?.name ?? "Разные исполнители")
                                                        .font(SN.text(.footnote))
                                                        .foregroundStyle(SN.inkMuted)
                                                        .lineLimit(1)
                                                }

                                                Spacer()

                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 22))
                                                    .foregroundStyle(SN.inkFaint)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(player.displayTrack?.title == item.title ? SN.ink.opacity(0.06) : Color.clear)
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 96)
            }
        }
        .navigationTitle(category.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isLoading = true
            results = await ym.searchAllFixed(query: category.searchQuery)
            isLoading = false
        }
        .task { await player.observeTimeline() }
    }
}
