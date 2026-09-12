import SwiftUI

// MARK: - Общие компоненты каталога

struct SonivoBackdrop: View {
    var body: some View {
        ZStack {
            AG.bg
            RadialGradient(
                colors: [AG.ember.opacity(0.16), Color.clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 430
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
                    .font(AG.display(.title2, .heavy))
                    .foregroundStyle(AG.ink)
                if let accent {
                    Text(accent)
                        .font(AG.serifAccent(.title2))
                        .foregroundStyle(AG.amber)
                }
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(AG.text(.caption))
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
                .font(AG.text(.caption2, .bold))
            Text(title)
                .font(AG.text(.footnote, isActive ? .bold : .medium))
        }
        .foregroundStyle(isActive ? Color.black.opacity(0.86) : AG.ink.opacity(0.82))
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .glassEffect(isActive ? .regular.tint(AG.amber).interactive() : .regular.interactive(), in: .capsule)
    }
}

struct SonivoMoreButton: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AG.text(.caption, .bold))
            Image(systemName: "chevron.right")
                .font(AG.text(.caption2, .black))
        }
        .foregroundStyle(AG.amber)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCapsule(interactive: true)
    }
}

struct RemoteArtwork: View {
    let urlString: String?
    var corner: CGFloat = 12

    var body: some View {
        Color.clear
            .overlay {
                if let value = urlString, let url = URL(string: value) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
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
                .font(AG.text(.body, .semibold))
                .foregroundStyle(AG.inkMuted)
        }
    }
}

struct RankedTrack: Identifiable {
    let rank: Int
    let item: YandexMusicService.YMTrackItem
    var id: String { String(rank) + "-" + item.id }
}

struct ChartRowView: View {
    let rank: Int?
    let item: YandexMusicService.YMTrackItem
    let onPlay: () -> Void

    @State private var player = PlayerCore.shared

    private var isCurrentPlaying: Bool {
        guard let current = player.currentTrack else { return false }
        return current.title == item.title && current.artist == item.artistName
    }

    private var firstArtistId: String? {
        guard let artist = item.artists?.first, let id = artist.id else { return nil }
        return String(id)
    }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                if let rank {
                    Text(String(rank))
                        .font(AG.display(.subheadline, .heavy).monospacedDigit())
                        .foregroundStyle(rank <= 3 ? AG.amber : AG.inkMuted)
                        .frame(width: 26, alignment: .center)
                }

                ZStack {
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
                        .font(AG.text(.subheadline, .semibold))
                        .foregroundStyle(isCurrentPlaying ? AG.amber : AG.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.artistName)
                        .font(AG.text(.caption, .medium))
                        .foregroundStyle(isCurrentPlaying ? AG.amber.opacity(0.75) : AG.inkMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                Menu {
                    Button { SonivoPlay.download(item) } label: {
                        Label("Скачать на iPhone", systemImage: "arrow.down.circle")
                    }
                    if let artistId = firstArtistId {
                        NavigationLink { ArtistView(artistId: artistId) } label: {
                            Label("К артисту", systemImage: "person.crop.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(AG.text(.subheadline, .bold))
                        .foregroundStyle(AG.inkMuted)
                        .frame(width: 32, height: AG.tapTarget)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: AG.radiusSmall, style: .continuous)
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
    private static let router = PlaybackCommandRouter.shared

    static func track(_ item: YandexMusicService.YMTrackItem, in list: [YandexMusicService.YMTrackItem]) {
        let service = YandexMusicService.shared
        service.endStationSession()
        let source = list.isEmpty ? [item] : list
        let queue = source.map { service.convertToTrack($0) }
        router.play(service.convertToTrack(item), queue: queue)
    }

    static func wave(_ station: YandexMusicService.StationOption) {
        let service = YandexMusicService.shared

        if station.stationId == "app:recap" {
            service.endStationSession()
            Task {
                var tracks = await service.buildRecapQueue(target: 40)
                if tracks.isEmpty { tracks = (try? await service.getChart()) ?? [] }
                guard !tracks.isEmpty else { return }
                let rankedQueue = UserTasteEngine.shared.filterAndRankWave(
                    tracks: tracks.map { service.convertToTrack($0) }
                )
                guard let first = rankedQueue.first else { return }
                router.play(first, queue: rankedQueue)
            }
            return
        }

        Task {
            service.beginStationSession(station.stationId)

            let firstBatch = (try? await service.getStationTracks(stationId: station.stationId)) ?? []
            let unplayed = firstBatch.filter { !service.isRecentlyPlayed(ymTrackId: $0.id) }
            let initial = unplayed.isEmpty ? firstBatch : unplayed
            let candidates = initial.isEmpty ? (try? await service.getChart()) ?? [] : initial

            if !candidates.isEmpty {
                let available = candidates
                    .map { service.convertToTrack($0) }
                    .filter { !UserTasteEngine.shared.dislikedTrackIDs.contains($0.id) }
                if let first = available.first {
                    router.play(first, queue: available)
                }
            }

            var tracks = await service.buildWaveQueue(stationId: station.stationId, target: 45)
            if tracks.isEmpty { tracks = (try? await service.getChart()) ?? [] }
            guard !tracks.isEmpty else { return }

            let filtered = tracks
                .map { service.convertToTrack($0) }
                .filter { !UserTasteEngine.shared.dislikedTrackIDs.contains($0.id) }

            if AutoMixEngineSelectionStore.shared.isV2Enabled {
                guard let current = AutoMixV2Runtime.shared.currentTrack else {
                    if let first = filtered.first { router.play(first, queue: filtered) }
                    return
                }
                var newQueue = filtered.filter { $0.id != current.id }
                newQueue.insert(current, at: 0)
                AutoMixV2Runtime.shared.replaceQueue(newQueue)
            } else if let current = PlayerCore.shared.currentTrack {
                var newQueue = filtered.filter { $0.id != current.id }
                newQueue.insert(current, at: 0)
                PlayerCore.shared.queue = newQueue
            } else if let first = filtered.first {
                router.play(first, queue: filtered)
            }
        }
    }

    static func album(_ album: YandexMusicService.YMAlbumItem) {
        let service = YandexMusicService.shared
        service.endStationSession()
        Task {
            let tracks = (try? await service.getAlbumTracks(albumId: album.id)) ?? []
            guard let first = tracks.first else { return }
            let queue = tracks.map { service.convertToTrack($0) }
            router.play(service.convertToTrack(first), queue: queue)
        }
    }

    static func download(_ item: YandexMusicService.YMTrackItem) {
        let service = YandexMusicService.shared
        Task {
            guard let info = try? await service.getStreamInfo(for: item.id) else { return }
            var track = service.convertToTrack(item)
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
