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
    @State private var showWaveSelector = false
    @State private var showPlayer = false

    private var moodStation: YandexMusicService.StationOption { ym.waveMoodStation }
    private var moodColors: [Color] {
        let cols = moodStation.gradient.compactMap { Color(hex: $0) }
        if cols.isEmpty {
            return [Color(hex: "#E5127D") ?? .pink, Color(hex: "#FF8C00") ?? .orange, Color(hex: "#FFE000") ?? .yellow]
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

    // MARK: - Top Bar (Яндекс * Музыка)

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
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: [Color(hex: "#FF334B")!, Color(hex: "#FF6A00")!], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 34, height: 34)
                            Text(String(user.displayName?.prefix(1) ?? user.login.prefix(1)).uppercased())
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: "#FF6B00") ?? .orange, Color(hex: "#FF1361") ?? .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                        Image(systemName: "person.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 0.8))
                }
            }
            .buttonStyle(GlassPressStyle())

            Spacer()

            // Center Title: Музыка
            Text("Музыка")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            // Search Icon
            NavigationLink {
                SearchCatalogView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(GlassPressStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: - Моя волна: Центральная сцена с сиянием и большой жёлтой кнопкой Play

    private var waveCenterStage: some View {
        ZStack(alignment: .center) {
            // 1. Анимированная плазма / аура с каустикой, спекулярными бликами и реакцией на звук
            FluidWaveView(
                colors: moodColors,
                isBackgroundMode: false
            )
            .frame(height: 380)
            .scaleEffect(1.08)
            .opacity(0.95)

            // 2. Радиальный градиентный свет
            RadialGradient(
                colors: [
                    (Color(hex: "#FFE000") ?? .yellow).opacity(0.35),
                    (Color(hex: "#FF007F") ?? .pink).opacity(0.25),
                    Color.clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 220
            )
            .frame(height: 380)
            .allowsHitTesting(false)

            // 3. Контент сцены
            VStack(spacing: 18) {
                // Заголовок "Моя волна"
                Text("Моя волна")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 14, x: 0, y: 4)

                // Большая жёлтая кнопка Play (80x80)
                Button {
                    handlePlayTap()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: "#FFE000") ?? .yellow)
                            .frame(width: 82, height: 82)
                            .shadow(color: (Color(hex: "#FFE000") ?? .yellow).opacity(player.isPlaying ? 0.65 : 0.35), radius: 24, x: 0, y: 6)

                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .black))
                            .foregroundStyle(.black)
                            .offset(x: player.isPlaying ? 0 : 3)
                    }
                }
                .buttonStyle(GlassPressStyle())
                .scaleEffect(player.isPlaying ? 1.04 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: player.isPlaying)

                // Трек в эфире (стеклянная капсула)
                if let track = player.currentTrack {
                    Button {
                        showPlayer = true
                    } label: {
                        HStack(spacing: 9) {
                            Text("\(track.title) — \(track.artist)")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Button {
                                library.toggleFavorite(track)
                            } label: {
                                Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(library.isTrackFavorite(track) ? Color(hex: "#FF2D55")! : .white.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
                    }
                    .buttonStyle(GlassPressStyle())
                }

                // AI Insight плашка
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "#FFE000") ?? .yellow)

                    Text("AI")
                        .font(.system(size: 9.5, weight: .black))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.white.opacity(0.18)))

                    Text(currentAiSubtitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.40), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if player.isPlaying {
            player.pause()
        } else {
            SonivoPlay.wave(moodStation)
        }
    }

    private var solidMoodBackdrop: some View {
        let accent = moodColors.first ?? Color(hex: "#FF334B")!
        return ZStack {
            Color(hex: "#09090B")!.ignoresSafeArea()
            accent.opacity(0.12).ignoresSafeArea()
        }
    }

    // MARK: - Карточки настроения (Компактные аккуратные кнопки)

    private var moodCardsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(MoodPreset.allCases) { preset in
                    LiquidGlassMoodCapsule(preset: preset) {
                        MoodRadioEngine.shared.start(mood: preset)
                    }
                    .frame(height: 48)
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
                                    .font(AG.text(13, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(10.5, .regular))
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
