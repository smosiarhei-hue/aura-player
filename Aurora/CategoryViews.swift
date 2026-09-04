import SwiftUI

// MARK: - 1. Favorites List View («Мне нравится»)

struct FavoritesListView: View {
    @State private var library = LibraryStore.shared
    @State private var player = PlayerCore.shared

    var body: some View {
        ZStack {
            SonivoBackdrop()

            if library.favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                    Text("В избранном пока ничего нет")
                        .font(AG.text(.headline, .bold))
                        .foregroundStyle(.white)
                    Text("Нажимайте на сердечко в плеере или треках, чтобы собирать любимую музыку здесь.")
                        .font(AG.text(.subheadline))
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Мне нравится")
                                    .font(AG.display(.title2, .bold))
                                    .foregroundStyle(.white)
                                Text("\(library.favorites.count) треков в коллекции")
                                    .font(AG.text(.footnote, .medium))
                                    .foregroundStyle(.white.opacity(0.65))

                                HStack(spacing: 10) {
                                    Button {
                                        if let first = library.favorites.first {
                                            player.play(first, newQueue: library.favorites)
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
                                            player.play(first, newQueue: shuffled)
                                        }
                                    } label: {
                                        Image(systemName: "shuffle")
                                            .font(AG.text(.subheadline, .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 32, height: 32)
                                            .background(Circle().fill(Color.white.opacity(0.12)))
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
                                Button {
                                    player.play(track, newQueue: library.favorites)
                                } label: {
                                    HStack(spacing: 12) {
                                        SmallArtwork(track: track, size: 46)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title)
                                                .font(AG.text(.subheadline, .semibold))
                                                .foregroundStyle(player.currentTrack?.id == track.id ? (AG.heart) : .white)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(AG.text(.footnote))
                                                .foregroundStyle(.white.opacity(0.60))
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Button {
                                            library.toggleFavorite(track)
                                        } label: {
                                            Image(systemName: "heart.fill")
                                                .font(AG.text(.callout, .semibold))
                                                .foregroundStyle(AG.heart)
                                                .frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(player.currentTrack?.id == track.id ? Color.white.opacity(0.06) : Color.clear)
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
        .navigationTitle("Мне нравится")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 2. History List View («История»)

struct HistoryListView: View {
    @State private var ym = YandexMusicService.shared
    @State private var library = LibraryStore.shared
    @State private var player = PlayerCore.shared

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
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                    Text("История прослушиваний пуста")
                        .font(AG.text(.headline, .bold))
                        .foregroundStyle(.white)
                    Text("Здесь будут сохраняться все треки, которые вы включали.")
                        .font(AG.text(.subheadline))
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("История прослушиваний")
                                    .font(AG.display(.title2, .bold))
                                    .foregroundStyle(.white)
                                Text("\(historyTracks.count) последних треков")
                                    .font(AG.text(.footnote))
                                    .foregroundStyle(.white.opacity(0.60))
                            }
                            Spacer()

                            Button {
                                ym.clearMemory()
                            } label: {
                                Text("Очистить")
                                    .font(AG.text(.footnote, .semibold))
                                    .foregroundStyle(.white.opacity(0.70))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.10)))
                            }
                            .buttonStyle(GlassPressStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                        LazyVStack(spacing: 4) {
                            ForEach(historyTracks) { track in
                                Button {
                                    player.play(track, newQueue: historyTracks)
                                } label: {
                                    HStack(spacing: 12) {
                                        SmallArtwork(track: track, size: 46)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title)
                                                .font(AG.text(.subheadline, .semibold))
                                                .foregroundStyle(player.currentTrack?.id == track.id ? AG.amber : .white)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(AG.text(.footnote))
                                                .foregroundStyle(.white.opacity(0.60))
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundStyle(.white.opacity(0.40))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(player.currentTrack?.id == track.id ? Color.white.opacity(0.06) : Color.clear)
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
    @State private var player = PlayerCore.shared
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
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(category.rawValue)
                                    .font(AG.display(.title, .black))
                                    .foregroundStyle(.white)
                                Text(category.subtitle)
                                    .font(AG.text(.footnote, .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(2)
                            }
                        }
                        .padding(20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if results.tracks.isEmpty && results.albums.isEmpty {
                        VStack(spacing: 8) {
                            Text("Ничего не найдено")
                                .font(AG.text(.callout, .bold))
                                .foregroundStyle(.white)
                            Text("Попробуйте обновить страницу")
                                .font(AG.text(.footnote))
                                .foregroundStyle(.white.opacity(0.60))
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
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
                                    .foregroundStyle(.white.opacity(0.60))
                            }
                            .padding(.horizontal, 16)
                        }

                        // Albums / Collections Section
                        if !results.albums.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Коллекции и циклы")
                                    .font(AG.text(.headline, .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(results.albums) { album in
                                            Button {
                                                SonivoPlay.album(album)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    RemoteArtwork(urlString: album.coverUrlString, corner: 14)
                                                        .frame(width: 130, height: 130)

                                                    Text(album.displayTitle)
                                                        .font(AG.text(.footnote, .semibold))
                                                        .foregroundStyle(.white)
                                                        .lineLimit(1)
                                                    Text(album.artistName)
                                                        .font(AG.text(.caption))
                                                        .foregroundStyle(.white.opacity(0.60))
                                                        .lineLimit(1)
                                                }
                                                .frame(width: 130)
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
                                    .foregroundStyle(.white)
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
                                                        .foregroundStyle(player.currentTrack?.title == item.title ? (category.gradient.first ?? .white) : .white)
                                                        .lineLimit(1)
                                                    Text(item.artists?.first?.name ?? "Разные исполнители")
                                                        .font(AG.text(.footnote))
                                                        .foregroundStyle(.white.opacity(0.60))
                                                        .lineLimit(1)
                                                }

                                                Spacer()

                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 22))
                                                    .foregroundStyle(.white.opacity(0.40))
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(player.currentTrack?.title == item.title ? Color.white.opacity(0.06) : Color.clear)
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
    }
}
