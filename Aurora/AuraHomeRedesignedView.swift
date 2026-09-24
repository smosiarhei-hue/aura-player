import SwiftUI

struct AuraHomeRedesignedView: View {
    @State private var player = ActivePlayerPresentation()
    @State private var ym = YandexMusicService.shared
    @State private var library = LibraryStore.shared
    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var newTracks: [YandexMusicService.YMTrackItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var showWaveSettings = false
    @State private var showPlayer = false
    @State private var waveStore = WaveSettingsStore.shared

    private var moodStation: YandexMusicService.StationOption { ym.waveMoodStation }
    private var waveColors: [Color] {
        let station = moodStation.gradient.compactMap(Color.init(hex:))
        let reference: [Color] = [
            Color(red: 1.0, green: 0.02, blue: 0.72),
            Color(red: 0.52, green: 0.08, blue: 1.0),
            Color(red: 1.0, green: 0.08, blue: 0.10),
            Color(red: 1.0, green: 0.55, blue: 0.03),
            Color(red: 0.10, green: 0.72, blue: 1.0)
        ]
        return station.isEmpty ? reference : Array((station + reference).prefix(5))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // Soft ambient blurred backdrop that adds depth and glow behind the whole screen
                RadialGradient(
                    colors: [
                        Color.cyan.opacity(0.18),
                        Color.purple.opacity(0.10),
                        Color.black
                    ],
                    center: .top,
                    startRadius: 40,
                    endRadius: 550
                )
                .blur(radius: 60)
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        header
                        waveHero
                        quickDestinations
                        moodSection
                        chartSection
                        newTracksSection
                    }
                    .padding(.bottom, 120)
                }
                .refreshable { await load(force: true) }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWaveSettings) { WaveSettingsSheet() }
            .fullScreenCover(isPresented: $showPlayer) { PlayerScreenV2(isPresented: $showPlayer) }
            .task { await player.observeTimeline() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                Task { await load(force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                if !ym.isDailyPremiereCacheValid {
                    Task { await load() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { showSettings = true } label: {
                Group {
                    if let avatar = ym.currentUser?.avatarUrl {
                        RemoteArtwork(urlString: avatar, corner: 15)
                    } else {
                        ZStack {
                            Circle().fill(.white.opacity(0.10))
                            Image(systemName: "sparkles").foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: waveColors, startPoint: .topLeading,
                                   endPoint: .bottomTrailing), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Профиль и настройки")

            VStack(alignment: .leading, spacing: 2) {
                Text("SONIVO").font(AG.text(.caption, .bold)).tracking(2.8)
                    .foregroundStyle(.white.opacity(0.62))
                Text("Музыка").font(AG.display(.title2, .bold)).foregroundStyle(.white)
            }
            Spacer()
            NavigationLink { SearchCatalogView() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 48, height: 48)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.top, 12)
    }

    private var waveHero: some View {
        ZStack(alignment: .bottom) {
            // Live Video Animation as the Hero Stage Background (scrolls naturally with the widget)
            MyWaveBackgroundVideoView(
                isPlaying: player.isPlaying,
                tintColors: player.displayTrack?.palette
            )
            .frame(height: 560)
            .clipped()
            .overlay {
                // Soft gradient dissolve into pure OLED black
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.40), location: 0.0),
                        .init(color: .clear, location: 0.16),
                        .init(color: .clear, location: 0.50),
                        .init(color: .black.opacity(0.60), location: 0.80),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            VStack(spacing: 12) {
                Spacer()

                Button(action: toggleWave) {
                    HStack(spacing: 14) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .black))
                        Text("Моя волна")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.70), radius: 20, y: 6)
                }
                .buttonStyle(TactileButtonStyle(scale: 0.94))
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Запустить Мою волну")

                // 1. Характер музыки прямо на главном экране
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WaveDiversity.allCases) { item in
                            let isSelected = waveStore.diversity == item
                            Button {
                                Haptics.tap(.light)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    waveStore.diversity = item
                                }
                                if player.isPlaying {
                                    Task { _ = await waveStore.reseedActiveWaveQueue() }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 12, weight: .bold))
                                    Text(item.title)
                                        .font(AG.text(.footnote, .semibold))
                                }
                                .foregroundStyle(isSelected ? Color.black : Color.white)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(
                                    isSelected ? Color.white : Color.white.opacity(0.12),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.18), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                // 2. Язык звучания + Кнопка всех настроек
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(WaveLanguage.allCases) { item in
                                let isSelected = waveStore.language == item
                                Button {
                                    Haptics.tap(.light)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        waveStore.language = item
                                    }
                                    if player.isPlaying {
                                        Task { _ = await waveStore.reseedActiveWaveQueue() }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 11, weight: .bold))
                                        Text(item.title)
                                            .font(AG.text(.caption, .semibold))
                                    }
                                    .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? Color.white : Color.white.opacity(0.08),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.14), lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 20)
                    }

                    Button { showWaveSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .glassCircle()
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .accessibilityLabel("Все настройки волны")
                }

                if let track = player.displayTrack {
                    Button { showPlayer = true } label: {
                        HStack(spacing: 11) {
                            SmallArtwork(track: track, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(AG.text(.subheadline, .bold)).lineLimit(1)
                                Text(track.artist).font(AG.text(.caption)).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.up").font(.caption.bold())
                        }
                        .foregroundStyle(.white).padding(10)
                        .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                }

                Spacer().frame(height: 16)
            }
        }
        .frame(height: 560)
        .frame(maxWidth: .infinity)
    }

    private var quickDestinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                NavigationLink { LibraryView() } label: {
                    quickCard("Для вас", subtitle: "Персональная музыка", icon: "person.2.fill", colors: [waveColors[0], waveColors[2]])
                }
                NavigationLink { TrendsExploreView() } label: {
                    quickCard("Тренды", subtitle: "Сейчас слушают", icon: "chart.line.uptrend.xyaxis", colors: [waveColors[1], waveColors[4]])
                }
                NavigationLink { LibraryView() } label: {
                    quickCard("Мне нравится", subtitle: "Любимые треки", icon: "heart.fill", colors: [Color.red, waveColors[0]])
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private func quickCard(_ title: String, subtitle: String, icon: String,
                           colors: [Color]) -> some View {
        HStack(spacing: 12) {
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AG.text(.headline, .bold)).foregroundStyle(.white)
                Text(subtitle).font(AG.text(.caption)).foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(14).frame(width: 245, alignment: .leading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Настроение", subtitle: "Измени характер своей волны")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(MoodPreset.allCases) { preset in
                        LiquidGlassMoodCapsule(preset: preset) {
                            Haptics.tap(.light); MoodRadioEngine.shared.start(mood: preset)
                        }
                    }
                }.padding(.horizontal, 16)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                Top100ChartView(title: "Чарт · Топ 100", tracks: chart)
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Чарт").font(AG.display(.title2, .bold)).foregroundStyle(.white)
                        Text("Главные треки сегодня").font(AG.text(.caption)).foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: AG.tapTarget, height: AG.tapTarget)
                }
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isLoading && chart.isEmpty { AuraLoadingState(title: "Обновляем чарт…") }
            else if let loadError, chart.isEmpty { AuraErrorState(message: loadError) { Task { await load() } } }
            else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(chart.prefix(6).enumerated()), id: \.element.id) { index, item in
                        AuraCatalogTrackRow(item: item, rank: index + 1) { SonivoPlay.track(item, in: chart) }
                    }
                }.padding(.horizontal, 12)
            }
        }
    }

    private var newTracksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink {
                PremiereTracksView(tracks: newTracks, title: "Топ-100 премьер")
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Премьера")
                            .font(AG.display(.title2, .bold))
                            .foregroundStyle(.white)
                        Text("Топ-100 премьер • Обновление в 00:00")
                            .font(AG.text(.caption))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: AG.tapTarget, height: AG.tapTarget)
                }
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LazyVStack(spacing: 2) {
                ForEach(Array(newTracks.prefix(5).enumerated()), id: \.element.id) { index, item in
                    AuraCatalogTrackRow(item: item, rank: index + 1) {
                        SonivoPlay.track(item, in: newTracks)
                    }
                }
            }
            .padding(.horizontal, 12)

            if !newTracks.isEmpty {
                NavigationLink {
                    PremiereTracksView(tracks: newTracks, title: "Топ-100 премьер")
                } label: {
                    HStack(spacing: 8) {
                        Text("Смотреть все 100 премьер")
                            .font(AG.text(.subheadline, .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(GlassPressStyle())
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(AG.display(.title2, .bold)).foregroundStyle(.white)
            Text(subtitle).font(AG.text(.caption)).foregroundStyle(.white.opacity(0.48))
        }.padding(.horizontal, 20)
    }

    private func toggleWave() {
        Haptics.tap(.medium)
        if player.isPlaying { player.pause() }
        else { SonivoPlay.wave(moodStation) }
    }

    private func load(force: Bool = false) async {
        isLoading = true; loadError = nil
        do { chart = try await ym.getChart(force: force) }
        catch { chart = []; loadError = "Не удалось обновить чарт. Проверь подключение к Яндекс Музыке." }
        newTracks = await ym.getNewTracks(limit: 100, force: force)
        isLoading = false
    }
}
