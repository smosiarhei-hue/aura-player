import SwiftUI

// MARK: - Общие компоненты каталога (Ember)

struct SonivoBackdrop: View {
    var body: some View {
        ZStack {
            AG.bg
            RadialGradient(
                colors: [AG.ember.opacity(0.22), Color.clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 430
            )
            RadialGradient(
                colors: [AG.amber.opacity(0.13), Color.clear],
                center: .bottomLeading,
                startRadius: 8,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

struct SonivoHeader: View {
    let title: String
    var accent: String? = nil
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(AG.display(22, .heavy))
                    .foregroundStyle(AG.ink)
                if let accent {
                    Text(accent)
                        .font(AG.serifAccent(22))
                        .foregroundStyle(AG.amber)
                }
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(AG.text(12, .regular))
                    .foregroundStyle(AG.inkMuted)
                    .lineLimit(2)
            }
        }
    }
}

struct SonivoChip: View {
    let title: String
    let icon: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(AG.text(12.5, isActive ? .bold : .medium))
        }
        .foregroundStyle(isActive ? Color.black.opacity(0.86) : AG.ink.opacity(0.82))
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isActive ? AnyShapeStyle(AG.emberGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            Capsule().strokeBorder(
                isActive ? AnyShapeStyle(Color.clear) : AnyShapeStyle(AG.hairline),
                lineWidth: 0.8
            )
        )
    }
}

struct SonivoMoreButton: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AG.text(12, .bold))
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .black))
        }
        .foregroundStyle(AG.amber)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(AG.amber.opacity(0.14)))
    }
}

/// Обложка из сети. Color.clear + overlay гарантирует, что картинка никогда
/// не раздувает родительскую разметку.
struct RemoteArtwork: View {
    let urlString: String?
    var corner: CGFloat = 12

    var body: some View {
        Color.clear
            .overlay {
                if let s = urlString, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(AG.hairline, lineWidth: 0.8)
            )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [AG.coal, AG.card], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AG.inkMuted)
        }
    }
}

/// Обёртка для нумерованных списков — стабильный id без enumerated().
struct RankedTrack: Identifiable {
    let rank: Int
    let item: YandexMusicService.YMTrackItem
    var id: String { String(rank) + "-" + item.id }
}

/// Строка трека: обложка и название запускают воспроизведение,
/// Строка трека: вся карточка кликабельна в любую точку с пружинным откликом и живым эквалайзером
struct ChartRowView: View {
    let rank: Int?
    let item: YandexMusicService.YMTrackItem
    let onPlay: () -> Void

    @State private var player = PlayerCore.shared

    private var isCurrentPlaying: Bool {
        guard let cur = player.currentTrack else { return false }
        return cur.title == item.title && cur.artist == item.artistName
    }

    private var firstArtistId: String? {
        guard let a = item.artists?.first, let id = a.id else { return nil }
        return String(id)
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if let rank {
                    Text(String(rank))
                        .font(AG.display(15, .heavy).monospacedDigit())
                        .foregroundStyle(rank <= 3 ? AG.amber : AG.inkMuted)
                        .frame(width: 26, alignment: .center)
                }

                ZStack(alignment: .center) {
                    RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                        .frame(width: 50, height: 50)

                    if isCurrentPlaying {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 50, height: 50)
                        LiveWaveEqualizer(isPlaying: player.isPlaying, color: AG.amber)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AG.text(14, .semibold))
                        .foregroundStyle(isCurrentPlaying ? AG.amber : AG.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(item.artistName)
                        .font(AG.text(11.5, .medium))
                        .foregroundStyle(isCurrentPlaying ? AG.amber.opacity(0.75) : AG.inkMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                Menu {
                    Button {
                        SonivoPlay.download(item)
                    } label: {
                        Label("Скачать на iPhone", systemImage: "arrow.down.circle")
                    }

                    if let artistId = firstArtistId {
                        NavigationLink {
                            ArtistView(artistId: artistId)
                        } label: {
                            Label("К артисту", systemImage: "person.crop.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AG.inkMuted)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isCurrentPlaying ? AG.card.opacity(0.92) : Color.white.opacity(0.001))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - Единая точка запуска воспроизведения

@MainActor
enum SonivoPlay {
    static func track(_ item: YandexMusicService.YMTrackItem, in list: [YandexMusicService.YMTrackItem]) {
        let ym = YandexMusicService.shared
        ym.endStationSession()
        let source = list.isEmpty ? [item] : list
        let queue = source.map { ym.convertToTrack($0) }
        PlayerCore.shared.play(ym.convertToTrack(item), newQueue: queue)
    }

    static func wave(_ station: YandexMusicService.StationOption) {
        let ym = YandexMusicService.shared

        // «Итоги» — не ротор Яндекса, а персональный рекап по реальному
        // вкусу пользователя (см. YandexMusicService.buildRecapQueue).
        if station.stationId == "app:recap" {
            ym.endStationSession()
            Task {
                var tracks = await ym.buildRecapQueue(target: 40)
                if tracks.isEmpty { tracks = (try? await ym.getChart()) ?? [] }
                guard !tracks.isEmpty else { return }
                let converted = tracks.map { ym.convertToTrack($0) }
                let rankedQueue = UserTasteEngine.shared.filterAndRankWave(tracks: converted)
                guard let first = rankedQueue.first else { return }
                PlayerCore.shared.play(first, newQueue: rankedQueue)
            }
            return
        }

        Task {
            ym.beginStationSession(station.stationId)

            // FAST START: fetch first quick batch (~200ms) and launch immediately!
            let firstBatch = await ym.fetchRotorBatch(stationId: station.stationId, queueSeed: nil)
            let initial = firstBatch.isEmpty ? (try? await ym.getChart()) ?? [] : firstBatch
            if !initial.isEmpty {
                let convertedInitial = initial.map { ym.convertToTrack($0) }
                let rankedInitial = UserTasteEngine.shared.filterAndRankWave(tracks: convertedInitial)
                if let first = rankedInitial.first {
                    PlayerCore.shared.play(first, newQueue: rankedInitial)
                }
            }

            // BACKGROUND EXPANSION: load full queue without blocking audio
            var tracks = await ym.buildWaveQueue(stationId: station.stationId, target: 45)
            if tracks.isEmpty {
                tracks = (try? await ym.getChart()) ?? []
            }
            guard !tracks.isEmpty else { return }
            var converted = tracks.map { ym.convertToTrack($0) }

            let isMoodOrActivitySpecific = station.stationId.hasPrefix("mood:") || station.stationId.hasPrefix("activity:")
            if station.stationId != "user:onyourwave" && !isMoodOrActivitySpecific {
                let favourite = await ym.personalPicks(limit: 8)
                if !favourite.isEmpty {
                    var seenIds = Set(tracks.map(\.id))
                    let extra = favourite.filter { !seenIds.contains($0.id) }
                    for item in extra { seenIds.insert(item.id) }
                    converted.append(contentsOf: extra.map { ym.convertToTrack($0) })
                }
            }

            let rankedQueue = UserTasteEngine.shared.filterAndRankWave(tracks: converted)
            if let current = PlayerCore.shared.currentTrack {
                if !rankedQueue.contains(where: { $0.id == current.id }) {
                    PlayerCore.shared.queue = [current] + rankedQueue
                } else {
                    PlayerCore.shared.queue = rankedQueue
                }
            } else if let first = rankedQueue.first {
                PlayerCore.shared.play(first, newQueue: rankedQueue)
            }
        }
    }

    static func album(_ album: YandexMusicService.YMAlbumItem) {
        let ym = YandexMusicService.shared
        ym.endStationSession()
        Task {
            let tracks = (try? await ym.getAlbumTracks(albumId: album.id)) ?? []
            guard let first = tracks.first else { return }
            let queue = tracks.map { ym.convertToTrack($0) }
            PlayerCore.shared.play(ym.convertToTrack(first), newQueue: queue)
        }
    }

    static func download(_ item: YandexMusicService.YMTrackItem) {
        let ym = YandexMusicService.shared
        Task {
            guard let info = try? await ym.getStreamInfo(for: item.id) else { return }
            var track = ym.convertToTrack(item)
            track.streamUrlString = info.url.absoluteString
            await LibraryStore.shared.saveOnlineTrackLocally(track: track)
        }
    }
}

// MARK: - Топ-100

struct Top100ChartView: View {
    let title: String
    let tracks: [YandexMusicService.YMTrackItem]

    private var ranked: [RankedTrack] {
        tracks.enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }
    }

    var body: some View {
        ZStack {
            SonivoBackdrop()

            ScrollView {
                LazyVStack(spacing: 2) {
                    SonivoHeader(
                        title: "Топ",
                        accent: "100",
                        subtitle: "Самые популярные треки прямо сейчас · " + String(tracks.count) + " треков"
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                    ForEach(ranked) { row in
                        ChartRowView(rank: row.rank, item: row.item) {
                            SonivoPlay.track(row.item, in: tracks)
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: - Секции вкладки «Новое»

enum NewSection: String, CaseIterable, Identifiable {
    case fresh
    case popular
    case listening
    case top100

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fresh:     return "Новинки"
        case .popular:   return "Популярное"
        case .listening: return "Сейчас слушают"
        case .top100:    return "Топ 100"
        }
    }

    var icon: String {
        switch self {
        case .fresh:     return "sparkles"
        case .popular:   return "flame.fill"
        case .listening: return "headphones"
        case .top100:    return "chart.bar.fill"
        }
    }
}
