import SwiftUI

// MARK: - 1. Favorites List View («Мне нравится»)

struct FavoritesListView: View {
    @State private var library = LibraryStore.shared
    @State private var player = ActivePlayerPresentation()

    var body: some View {
        ZStack {
            SonivoBackdrop()

            if library.favorites.isEmpty {
                AuraEmptyState(
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
                                    .fill(LinearGradient(colors: AG.Tile.red, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 84, height: 84)
                                    .shadow(color: AG.heart.opacity(0.40), radius: 12, y: 6)

                                Image(systemName: "heart.fill")
                                    .font(.system(size: 40, weight: .bold))
                                    .foregroundStyle(AG.ink)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Мне нравится")
                                    .font(AG.display(.title2, .bold))
                                    .foregroundStyle(AG.ink)
                                Text("\(library.favorites.count) треков в коллекции")
                                    .font(AG.text(.footnote, .medium))
                                    .foregroundStyle(AG.inkMuted)

                                HStack(spacing: 10) {
                                    Button {
                                        if let first = library.favorites.first {
                                            PlaybackCommandRouter.shared.play(first, queue: library.favorites)
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "play.fill")
                                                .font(AG.text(.caption, .bold))
                                            Text("Слушать")
                                                .font(AG.text(.footnote, .bold))
                                        }
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(.white))
                                    }
                                    .buttonStyle(GlassPressStyle())

                                    Button {
                                        let shuffled = library.favorites.shuffled()
                                        if let first = shuffled.first {
                                            PlaybackCommandRouter.shared.play(first, queue: shuffled)
                                        }
                                    } label: {
                                        Image(systemName: "shuffle")
                                            .font(AG.text(.subheadline, .bold))
                                            .foregroundStyle(AG.ink)
                                            .frame(width: 32, height: 32)
                                            .background(Circle().fill(AG.ink.opacity(0.12)))
                                    }
                                    .buttonStyle(GlassPressStyle())
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
                                                    .font(AG.text(.subheadline, .semibold))
                                                    .foregroundStyle(player.displayTrack?.id == track.id ? AG.heart : .white)
                                                    .lineLimit(1)
                                                Text(track.artist)
                                                    .font(AG.text(.footnote))
                                                    .foregroundStyle(AG.inkMuted)
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
                                            .font(AG.text(.callout, .semibold))
                                            .foregroundStyle(AG.heart)
                                            .frame(width: AG.tapTarget, height: AG.tapTarget)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Убрать из избранного")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(player.displayTrack?.id == track.id ? AG.ink.opacity(0.06) : Color.clear)
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
                AuraEmptyState(
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
                                    .font(AG.display(.title2, .bold))
                                                    .foregroundStyle(AG.ink)
                                Text("\(historyTracks.count) последних треков")
                                    .font(AG.text(.footnote))
                                                    .foregroundStyle(AG.inkMuted)
                            }
                            Spacer()

                            Button {
                                ym.clearMemory()
                            } label: {
                                Text("Очистить")
                                    .font(AG.text(.footnote, .semibold))
                                    .foregroundStyle(AG.inkMuted)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(AG.ink.opacity(0.10)))
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
                                                .font(AG.text(.subheadline, .semibold))
                                                .foregroundStyle(player.displayTrack?.id == track.id ? AG.amber : .white)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(AG.text(.footnote))
                                                .foregroundStyle(AG.inkMuted)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 24))
                                                .foregroundStyle(AG.inkFaint)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(player.displayTrack?.id == track.id ? AG.ink.opacity(0.06) : Color.clear)
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
        case .books: return AG.Tile.blue
        case .kids: return AG.Tile.orange
        case .podcasts: return AG.Tile.green
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
                                .foregroundStyle(AG.ink)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(category.rawValue)
                                    .font(AG.display(.title, .black))
                                    .foregroundStyle(AG.ink)
                                Text(category.subtitle)
                                    .font(AG.text(.footnote, .medium))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(2)
                            }
                        }
                        .padding(20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if isLoading {
                        AuraLoadingState(title: "Загружаем подборку…")
                    } else if results.tracks.isEmpty && results.albums.isEmpty {
                        AuraEmptyState(
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
                                            .font(AG.text(.caption, .bold))
                                        Text("Слушать подборку")
                                            .font(AG.text(.subheadline, .bold))
                                    }
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(.white))
                                }
                                .buttonStyle(GlassPressStyle())

                                Spacer()

                                Text("\(results.tracks.count) выпусков")
                                    .font(AG.text(.footnote, .medium))
                                    .foregroundStyle(AG.inkMuted)
                            }
                            .padding(.horizontal, 16)
                        }

                        // Albums / Collections Section
                        if !results.albums.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Коллекции и циклы")
                                    .font(AG.text(.headline, .bold))
                                    .foregroundStyle(AG.ink)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(results.albums) { album in
                                            Button {
                                                SonivoPlay.album(album)
                                            } label: {
                                                AuraArtworkCard(title: album.displayTitle, subtitle: album.artistName, width: 130) {
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
                                    .font(AG.text(.headline, .bold))
                                    .foregroundStyle(AG.ink)
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
                                                        .font(AG.text(.subheadline, .semibold))
                                                        .foregroundStyle(player.displayTrack?.title == item.title ? (category.gradient.first ?? .white) : .white)
                                                        .lineLimit(1)
                                                    Text(item.artists?.first?.name ?? "Разные исполнители")
                                                        .font(AG.text(.footnote))
                                                        .foregroundStyle(AG.inkMuted)
                                                        .lineLimit(1)
                                                }

                                                Spacer()

                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 22))
                                                    .foregroundStyle(AG.inkFaint)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(player.displayTrack?.title == item.title ? AG.ink.opacity(0.06) : Color.clear)
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
