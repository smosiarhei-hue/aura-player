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
                SonivoBackdrop()

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
            .buttonStyle(GlassPressStyle())

            Spacer()

            // Center Logo: Яндекс ✳ Музыка
            HStack(spacing: 5) {
                Text("Яндекс")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Image(systemName: "asterisk")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color(hex: "#FFE000") ?? .yellow)

                Text("Музыка")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

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
            // 1. Анимированная плазма / аура (Magenta / Yellow / Amber)
            FluidWaveView(
                colors: moodColors,
                isBackgroundMode: true
            )
            .frame(height: 380)
            .scaleEffect(1.15)
            .blur(radius: 20)
            .opacity(0.85)

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
        if let current = player.currentTrack {
            return "Поток настроен под \(current.artist)"
        }
        return "Индивидуальный поток под твой вкус и ритм"
    }

    private func handlePlayTap() {
        if player.isPlaying {
            player.pause()
        } else if player.currentTrack != nil {
            player.resume()
        } else {
            SonivoPlay.wave(moodStation)
        }
    }

    // MARK: - Карточки снизу (Настроения и занятия как на скриншоте)

    private var moodCardsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // 1. Время помечтать
                moodCard(
                    title: "Время помечтать",
                    icon: "sparkle",
                    colors: [Color(hex: "#E040FB") ?? .pink, Color(hex: "#9C27B0") ?? .purple],
                    stationId: "mood:dream"
                )

                // 2. Бежать быстрее ветра
                moodCard(
                    title: "Бежать быстрее\nветра",
                    icon: "figure.run",
                    colors: [Color(hex: "#00B0FF") ?? .blue, Color(hex: "#0055FF") ?? .indigo],
                    stationId: "activity:running"
                )

                // 3. Распаковать итоги лета
                moodCard(
                    title: "Распаковать\nитоги ↗",
                    icon: "gift.fill",
                    colors: [Color(hex: "#FF9100") ?? .orange, Color(hex: "#FF3D00") ?? .red],
                    stationId: "app:recap"
                )

                // 4. Заряд энергии
                moodCard(
                    title: "Заряд\nэнергии",
                    icon: "bolt.fill",
                    colors: [Color(hex: "#AEEA00") ?? .green, Color(hex: "#64DD17") ?? .yellow],
                    stationId: "mood:energy"
                )

                // 5. Спокойствие
                moodCard(
                    title: "Спокойствие\nи баланс",
                    icon: "leaf.fill",
                    colors: [Color(hex: "#00E5FF") ?? .cyan, Color(hex: "#1DE9B6") ?? .teal],
                    stationId: "mood:calm"
                )
            }
            .padding(.horizontal, 16)
        }
    }

    private func moodCard(title: String, icon: String, colors: [Color], stationId: String) -> some View {
        Button {
            let station = YandexMusicService.rotorStations.first(where: { $0.stationId == stationId })
                ?? YandexMusicService.StationOption(title: title.replacingOccurrences(of: "\n", with: " "), subtitle: "Моя волна", icon: icon, gradient: ["0A84FF", "30D158"], stationId: stationId)
            SonivoPlay.wave(station)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // 3D светящаяся сфера
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [colors.first?.opacity(0.95) ?? .pink, colors.last?.opacity(0.40) ?? .purple, Color.clear],
                                center: .center,
                                startRadius: 4,
                                endRadius: 36
                            )
                        )
                        .frame(width: 60, height: 60)
                        .blur(radius: 4)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .shadow(color: (colors.first ?? .blue).opacity(0.50), radius: 10, x: 0, y: 4)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                // Текст названия карточки
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(width: 136, height: 140)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(hex: "#1A1A1E")?.opacity(0.85) ?? Color.black.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
        }
        .buttonStyle(GlassPressStyle())
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
