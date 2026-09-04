import SwiftUI

// MARK: - Tab 1: Моя волна (Yandex Music Style)

struct HomeView: View {
    @State private var player = PlayerCore.shared
    @State private var ym = YandexMusicService.shared
    @State private var library = LibraryStore.shared

    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var albums: [YandexMusicService.YMAlbumItem] = []
    @State private var isLoading = false
    @State private var showSettings = false
    @State private var showPlayer = false

    private var moodStation: YandexMusicService.StationOption { ym.waveMoodStation }
    private var moodColors: [Color] {
        let cols = moodStation.gradient.compactMap { Color(hex: $0) }
        if cols.isEmpty {
            return [AG.flame, AG.ember, AG.amber]
        }
        return cols
    }

    private var topFive: [RankedTrack] {
        chart.prefix(5).enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                solidMoodBackdrop

                ScrollView {
                    VStack(spacing: 22) {
                        yandexTopBar

                        waveCenterStage

                        moodCardsSection

                        chartSection

                        albumsSection
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 96)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPlayer) {
                PlayerScreenV2(isPresented: $showPlayer)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(38)
                    .presentationBackground(.clear)
            }
            .task { await load() }
        }
    }

    // MARK: - Top Bar

    private var yandexTopBar: some View {
        HStack(alignment: .center) {
            // User avatar
            Button {
                showSettings = true
            } label: {
                if let user = ym.currentUser {
                    if let avatar = user.avatarUrl {
                        RemoteArtwork(urlString: avatar, corner: 10)
                            .frame(width: 34, height: 34)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(AG.emberGradient)
                                .frame(width: 34, height: 34)
                            Text(String(user.displayName?.prefix(1) ?? user.login.prefix(1)).uppercased())
                                .font(AG.text(.subheadline, .bold))
                                .foregroundStyle(AG.ink)
                        }
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AG.emberGradient)
                            .frame(width: 34, height: 34)
                        Image(systemName: "person.fill")
                            .font(AG.text(.callout, .bold))
                            .foregroundStyle(AG.ink)
                    }
                }
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Профиль и настройки")

            Spacer()

            Text("Музыка")
                .font(AG.rounded(.title2, .bold))
                .foregroundStyle(AG.ink)

            Spacer()

            NavigationLink {
                SearchCatalogView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(AG.glyph(.bold))
                    .foregroundStyle(AG.ink)
                    .frame(width: AG.tapTarget, height: AG.tapTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .accessibilityLabel("Поиск")
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: - Моя волна: центральная сцена

    private var waveCenterStage: some View {
        ZStack(alignment: .center) {
            FluidWaveView(
                colors: moodColors,
                isBackgroundMode: false
            )
            .frame(height: 380)
            .scaleEffect(1.08)
            .opacity(0.95)

            RadialGradient(
                colors: [
                    (moodColors.first ?? AG.amber).opacity(0.30),
                    (moodColors.last ?? AG.ember).opacity(0.18),
                    Color.clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 220
            )
            .frame(height: 380)
            .allowsHitTesting(false)

            VStack(spacing: 18) {
                Text("Моя волна")
                    .font(AG.rounded(.largeTitle, .heavy))
                    .foregroundStyle(AG.ink)
                    .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 4)

                Button {
                    handlePlayTap()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(AG.ink)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 82, height: 82)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(moodColors.first ?? AG.amber).interactive(), in: .circle)
                .scaleEffect(player.isPlaying ? 1.04 : 1.0)
                .animation(AG.spring, value: player.isPlaying)
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Запустить Мою волну")

                if let track = player.currentTrack {
                    Button {
                        showPlayer = true
                    } label: {
                        HStack(spacing: 9) {
                            Text("\(track.title) — \(track.artist)")
                                .font(AG.text(.footnote, .semibold))
                                .foregroundStyle(AG.ink)
                                .lineLimit(1)

                            Button {
                                Haptics.tap(.light)
                                library.toggleFavorite(track)
                            } label: {
                                Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                                    .font(AG.text(.footnote, .bold))
                                    .foregroundStyle(library.isTrackFavorite(track) ? AG.heart : AG.ink.opacity(0.85))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("В избранное")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(interactive: true)
                    .accessibilityLabel("Открыть плеер")
                }

                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(AG.text(.caption, .bold))
                        .foregroundStyle(AG.amber)

                    Text(currentAiSubtitle)
                        .font(AG.text(.caption, .medium))
                        .foregroundStyle(AG.ink.opacity(0.88))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .glassCapsule()
            }
            .padding(.vertical, 24)
        }
        .frame(height: 360)
    }

    private var currentAiSubtitle: String {
        if let mood = MoodRadioEngine.shared.activeMood {
            return "Радио настроения: \(mood.title.replacingOccurrences(of: "\n", with: " "))"
        }
        if let current = player.currentTrack {
            return "Поток настроен под \(current.artist)"
        }
        return "Индивидуальный поток под твой вкус и ритм"
    }

    private func handlePlayTap() {
        Haptics.tap(.medium)
        if player.isPlaying {
            player.pause()
        } else {
            SonivoPlay.wave(moodStation)
        }
    }

    private var solidMoodBackdrop: some View {
        let accent = moodColors.first ?? AG.ember
        return ZStack {
            AG.bg.ignoresSafeArea()
            accent.opacity(0.12).ignoresSafeArea()
        }
    }

    // MARK: - Карточки настроения (Компактные аккуратные кнопки)

    private var moodCardsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(MoodPreset.allCases) { preset in
                        LiquidGlassMoodCapsule(preset: preset) {
                            Haptics.tap(.light)
                            MoodRadioEngine.shared.start(mood: preset)
                        }
                        .frame(height: 48)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Чарт

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                SonivoHeader(title: "Чарт", accent: "сегодня")
                Spacer()
                NavigationLink {
                    Top100ChartView(title: "Чарт", tracks: chart)
                } label: {
                    SonivoMoreButton(title: "Все")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if isLoading && chart.isEmpty {
                ProgressView().tint(AG.amber).frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 2) {
                    ForEach(topFive) { row in
                        ChartRowView(rank: row.rank, item: row.item) {
                            SonivoPlay.track(row.item, in: chart)
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Свежие релизы

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Свежие", accent: "релизы")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(albums.prefix(12)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                                    .frame(width: 140, height: 140)

                                Text(album.displayTitle)
                                    .font(AG.text(.footnote, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(.caption2))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        isLoading = true
        chart = (try? await ym.getChart()) ?? []
        isLoading = false
        albums = (try? await ym.getNewAlbums()) ?? []
    }
}
