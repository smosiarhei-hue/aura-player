import SwiftUI

struct SonivoHomeRedesignedView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var antigravity = AntigravityTransitionManager.shared
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
    @State private var showAIAssistant = false
    @State private var waveStore = WaveSettingsStore.shared
    @State private var themeManager = ThemeFontManager.shared
    @State private var showShakeOverlay = false
    @State private var shakeTriggerCount = 0
    @State private var isWaveShaking = false
    @State private var shakeHUDMessage = "Волна встряхнута!"
    @State private var shakeHUDDetail = "Режим «Незнакомое» • Свежие открытия"
    @State private var lastShakeTimestamp: TimeInterval = 0

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

    private var shakeWavePalette: [Color] {
        [themeManager.accentColor, themeManager.flameColor]
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // Soft ambient blurred backdrop that adds depth and glow behind the whole screen
                RadialGradient(
                    colors: [
                        themeManager.accentColor.opacity(0.18),
                        themeManager.flameColor.opacity(0.10),
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
                        waveHero
                        quickDestinations
                        chartSection
                        newTracksSection
                    }
                    .padding(.bottom, 120)
                }
                .refreshable { await load(force: true) }

                // Native Apple Smooth Ambient Vignette under Dynamic Island / Status Bar
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.85),
                            Color.black.opacity(0.40),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 140)
                    .ignoresSafeArea(edges: .top)

                    Spacer()
                }
                .allowsHitTesting(false)

                // Native Apple Smooth Ambient Vignette at the bottom over Dock / Mini Player
                VStack(spacing: 0) {
                    Spacer()

                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.50),
                            Color.black.opacity(0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                    .ignoresSafeArea(edges: .bottom)
                }
                .allowsHitTesting(false)

                // Полноэкранная жидкостная анимация волны при встряхивании телефона
                WaveShakeOverlayView(
                    isActive: showShakeOverlay,
                    triggerCount: shakeTriggerCount,
                    palette: shakeWavePalette,
                    title: shakeHUDMessage,
                    subtitle: shakeHUDDetail,
                    onDismiss: {
                        showShakeOverlay = false
                        isWaveShaking = false
                    }
                )
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWaveSettings) { WaveSettingsSheet() }
            .fullScreenCover(isPresented: $showAIAssistant) { AIMusicAssistantView() }
            .fullScreenCover(isPresented: $showPlayer) { PlayerScreenV2(isPresented: $showPlayer) }
            .task { await player.observeTimeline() }
            .task { await load() }
            .onAppear { updateAntigravityLifecycle(isOnMain: true) }
            .onDisappear { updateAntigravityLifecycle(isOnMain: false) }
            .onChange(of: scenePhase) { _, _ in updateAntigravityLifecycle(isOnMain: true) }
            .onChange(of: showSettings) { _, _ in updateAntigravityLifecycle(isOnMain: true) }
            .onChange(of: showWaveSettings) { _, _ in updateAntigravityLifecycle(isOnMain: true) }
            .onChange(of: showAIAssistant) { _, _ in updateAntigravityLifecycle(isOnMain: true) }
            .onChange(of: showPlayer) { _, _ in updateAntigravityLifecycle(isOnMain: true) }
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShakeNotification)) { _ in
                guard scenePhase == .active && !showPlayer && !showSettings && !showWaveSettings && !showAIAssistant else { return }
                antigravity.handleSystemShakeNotification()
                triggerShakeWave()
            }
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


    private var waveHero: some View {
        MyWaveHeroView(
            player: player,
            showPlayer: $showPlayer,
            showSettings: $showSettings,
            showWaveSettings: $showWaveSettings,
            showAIAssistant: $showAIAssistant,
            onToggleWave: toggleWave,
            onShakeWave: { triggerShakeWave() },
            isWaveShaking: isWaveShaking
        )
    }

    private var quickDestinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // AI Музыкальный Куратор
                Button {
                    Haptics.tap(.medium)
                    showAIAssistant = true
                } label: {
                    quickCard(
                        "AI Куратор",
                        subtitle: "Плейлисты 2026",
                        icon: "wand.and.stars",
                        colors: [Color(hex: "#FF455B") ?? .pink, Color(hex: "#9333EA") ?? .purple]
                    )
                }
                .buttonStyle(TactileButtonStyle(scale: 0.96))

                // Пункт «Незнакомое» (быстрый переход в режим открытий и новых треков)
                Button {
                    Haptics.tap(.medium)
                    triggerShakeWave(forceDiscover: true)
                } label: {
                    quickCard(
                        "Незнакомое",
                        subtitle: "Новые открытия",
                        icon: "sparkles",
                        colors: [Color(red: 0.0, green: 0.95, blue: 0.99), Color(red: 0.31, green: 0.67, blue: 0.99)]
                    )
                }
                .buttonStyle(TactileButtonStyle(scale: 0.96))

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
                Text(title).font(SN.text(.headline, .bold)).foregroundStyle(.white)
                Text(subtitle).font(SN.text(.caption)).foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(14).frame(width: 245, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.60), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Настроение", subtitle: "Измени характер своей волны")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(MoodPreset.allCases) { preset in
                        LiquidGlassMoodCapsule(preset: preset) {
                            Haptics.tap(.light)
                            MoodRadioEngine.shared.start(mood: preset)
                            showPlayer = true
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
                        HStack(spacing: 8) {
                            Text("Чарт").font(SN.display(.title2, .bold)).foregroundStyle(.white)
                            AppleFlareIcon(name: "FlareChart", size: 26, glowColor: SN.amber)
                        }
                        Text("Главные треки сегодня").font(SN.text(.caption)).foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: SN.tapTarget, height: SN.tapTarget)
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))

            if isLoading && chart.isEmpty { SonivoLoadingState(title: "Обновляем чарт…") }
            else if let loadError, chart.isEmpty { SonivoErrorState(message: loadError) { Task { await load() } } }
            else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(chart.prefix(6).enumerated()), id: \.element.id) { index, item in
                        SonivoCatalogTrackRow(item: item, rank: index + 1) { 
                            SonivoPlay.track(item, in: chart)
                            showPlayer = true
                        }
                    }
                }.padding(.horizontal, 16)
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
                        HStack(spacing: 8) {
                            Text("Премьера")
                                .font(SN.display(.title2, .bold))
                                .foregroundStyle(.white)
                            AppleFlareIcon(name: "FlarePremiere", size: 26, glowColor: SN.ember)
                            ApplePremiereBadge(title: "ТОП-100")
                        }
                        Text("Топ-100 премьер • Обновление в 00:00")
                            .font(SN.text(.caption))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: SN.tapTarget, height: SN.tapTarget)
                }
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))

            LazyVStack(spacing: 2) {
                ForEach(Array(newTracks.prefix(5).enumerated()), id: \.element.id) { index, item in
                    SonivoCatalogTrackRow(item: item, rank: index + 1) {
                        SonivoPlay.track(item, in: newTracks)
                        showPlayer = true
                    }
                }
            }
            .padding(.horizontal, 16)

            if !newTracks.isEmpty {
                NavigationLink {
                    PremiereTracksView(tracks: newTracks, title: "Топ-100 премьер")
                } label: {
                    HStack(spacing: 8) {
                        Text("Смотреть все 100 премьер")
                            .font(SN.text(.subheadline, .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial.opacity(0.60), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(GlassPressStyle())
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(SN.display(.title2, .bold)).foregroundStyle(.white)
            Text(subtitle).font(SN.text(.caption)).foregroundStyle(.white.opacity(0.48))
        }.padding(.horizontal, 16)
    }

    private func toggleWave() {
        Haptics.tap(.medium)
        if player.isPlaying {
            player.pause()
        } else {
            SonivoPlay.wave(moodStation, forceFresh: true)
            showPlayer = true
        }
    }

    /// Логика встряхивания «Моей волны» (переключение на «Незнакомое», кинетический переход «Антигравити» и свежий поток)
    private func triggerShakeWave(forceDiscover: Bool = true) {
        guard scenePhase == .active && !showPlayer && !showSettings && !showWaveSettings else { return }

        let now = Date().timeIntervalSince1970
        guard now - lastShakeTimestamp > 1.2 else { return }
        lastShakeTimestamp = now

        // 1. Запуск кинетического перехода «Антигравити» (CoreHaptics, вихрь, 3D-кувырок, аудио-кроссфейд)
        antigravity.triggerShift(forceDiscover: forceDiscover)

        // 2. Запуск полноэкранной жидкостной анимации и пульсации обложки
        isWaveShaking = true
        shakeTriggerCount += 1
        showShakeOverlay = true

        // 3. Логика HUD
        if forceDiscover || waveStore.diversity != .discover {
            shakeHUDMessage = "Антигравити!"
            shakeHUDDetail = "Режим «Незнакомое» • Свежие открытия"
        } else {
            shakeHUDMessage = "Поток обновлен!"
            shakeHUDDetail = "Свежие треки в «Незнакомом»"
        }
    }

    // Proximity sensor disabled per user request: proximityState remains false so phone calls mode is never triggered
    private var proximityState: Bool { false }

    private func updateAntigravityLifecycle(isOnMain: Bool = true) {
        antigravity.updateLifecycle(
            isAppActive: scenePhase == .active,
            isModalActive: showSettings || showWaveSettings || showPlayer,
            isOnMainScreen: isOnMain
        )
    }

    private func load(force: Bool = false) async {
        isLoading = true; loadError = nil
        do { chart = try await ym.getChart(force: force) }
        catch { chart = []; loadError = "Не удалось обновить чарт. Проверь подключение к Яндекс Музыке." }
        newTracks = await ym.getNewTracks(limit: 100, force: force)
        isLoading = false
    }
}
