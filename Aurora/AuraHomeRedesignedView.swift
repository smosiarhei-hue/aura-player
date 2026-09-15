import SwiftUI

struct AuraHomeRedesignedView: View {
    @State private var player = ActivePlayerPresentation()
    @State private var ym = YandexMusicService.shared
    @State private var library = LibraryStore.shared
    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var albums: [YandexMusicService.YMAlbumItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var showPlayer = false

    private var moodStation: YandexMusicService.StationOption { ym.waveMoodStation }
    private var moodColors: [Color] {
        let colors = moodStation.gradient.compactMap { Color(hex: $0) }
        return colors.isEmpty ? [AG.flame, AG.ember, AG.amber] : colors
    }
    private var currentTrack: Track? { player.displayTrack }
    private var topThree: [RankedTrack] {
        chart.prefix(3).enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuraScreenBackground(colors: moodColors)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        hero
                        moodSection
                        chartSection
                        releasesSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
                .refreshable { await load() }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showPlayer) {
                PlayerScreenV2(isPresented: $showPlayer)
            }
            .task { await player.observeTimeline() }
            .task { await load() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { showSettings = true } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AG.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Профиль и настройки")

            VStack(alignment: .leading, spacing: 2) {
                Text("AURA")
                    .font(AG.text(.caption, .bold))
                    .tracking(2.4)
                    .foregroundStyle(AG.amber)
                Text("Музыка для твоего ритма")
                    .font(AG.display(.title3, .bold))
                    .foregroundStyle(AG.ink)
            }

            Spacer()

            NavigationLink { SearchCatalogView() } label: {
                Image(systemName: "magnifyingglass")
                    .font(AG.glyph(.bold))
                    .foregroundStyle(AG.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .accessibilityLabel("Поиск")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                AuraStatusBadge(title: "МОЯ ВОЛНА", systemImage: "sparkles", tint: moodColors.first ?? AG.amber)
                Spacer()
                if player.isPlaying {
                    LiveWaveEqualizer(isPlaying: true, color: AG.amber, barCount: 4)
                }
            }

            HStack(spacing: 18) {
                artwork

                VStack(alignment: .leading, spacing: 7) {
                    Text(currentTrack == nil ? "Готово к прослушиванию" : "Сейчас играет")
                        .font(AG.text(.caption, .semibold))
                        .foregroundStyle(AG.inkMuted)
                    Text(currentTrack?.title ?? "Запусти свою волну")
                        .font(AG.display(.title3, .bold))
                        .foregroundStyle(AG.ink)
                        .lineLimit(2)
                    Text(currentTrack?.artist ?? "Персональные рекомендации под настроение")
                        .font(AG.text(.subheadline))
                        .foregroundStyle(AG.inkMuted)
                        .lineLimit(2)

                    Button {
                        Haptics.tap(.medium)
                        if player.isPlaying { player.pause() } else { SonivoPlay.wave(moodStation) }
                    } label: {
                        Label(player.isPlaying ? "Пауза" : "Слушать", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(AG.text(.subheadline, .bold))
                            .foregroundStyle(.black.opacity(0.88))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                    }
                    .glassProminent(moodColors.first ?? AG.amber)
                    .buttonStyle(GlassPressStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private var artwork: some View {
        if let currentTrack {
            SmallArtwork(track: currentTrack, size: 132)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            FluidWaveView(colors: moodColors, isBackgroundMode: false, isPlaying: player.isPlaying)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuraSectionHeader(title: "Настроение", subtitle: "Выбери направление для новой волны")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(MoodPreset.allCases) { preset in
                        LiquidGlassMoodCapsule(preset: preset) {
                            Haptics.tap(.light)
                            MoodRadioEngine.shared.start(mood: preset)
                        }
                    }
                }
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                AuraSectionHeader(title: "Чарт", subtitle: "Три трека, которые сейчас слушают")
                NavigationLink {
                    Top100ChartView(title: "Чарт", tracks: chart)
                } label: {
                    Text("Все")
                        .font(AG.text(.footnote, .semibold))
                        .foregroundStyle(AG.amber)
                        .frame(minWidth: AG.tapTarget, minHeight: AG.tapTarget)
                }
            }

            if isLoading && chart.isEmpty {
                AuraLoadingState(title: "Обновляем чарт…")
            } else if let loadError, chart.isEmpty {
                AuraErrorState(message: loadError) { Task { await load() } }
            } else {
                VStack(spacing: 4) {
                    ForEach(topThree) { row in
                        ChartRowView(rank: row.rank, item: row.item) {
                            SonivoPlay.track(row.item, in: chart)
                        }
                    }
                }
                .padding(8)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }

    private var releasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuraSectionHeader(title: "Свежие релизы", subtitle: "Новинки из Яндекс Музыки")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(albums.prefix(8)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            AuraArtworkCard(title: album.displayTitle, subtitle: album.artistName, width: 128) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 18)
                            }
                        }
                        .buttonStyle(GlassPressStyle())
                        .contextMenu {
                            Button { SonivoPlay.album(album) } label: {
                                Label("Слушать релиз", systemImage: "play.fill")
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            chart = try await ym.getChart()
        } catch {
            chart = []
            loadError = "Не удалось обновить чарт. Проверь подключение к Яндекс Музыке."
        }
        albums = (try? await ym.getNewAlbums()) ?? []
        isLoading = false
    }
}
