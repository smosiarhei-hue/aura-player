import SwiftUI

struct AuraHomeRedesignedView: View {
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
    @State private var waveStore = WaveSettingsStore.shared
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

    private var trackPalette: [Color] {
        if let palette = player.displayTrack?.palette, !palette.isEmpty {
            return palette
        }
        return waveColors
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
                        waveHero
                        quickDestinations
                        moodSection
                        chartSection
                        newTracksSection
                    }
                    .padding(.bottom, 120)
                }
                .refreshable { await load(force: true) }

                // Полноэкранная жидкостная анимация волны при встряхивании телефона
                WaveShakeOverlayView(
                    isActive: showShakeOverlay,
                    triggerCount: shakeTriggerCount,
                    palette: trackPalette,
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
            .fullScreenCover(isPresented: $showPlayer) { PlayerScreenV2(isPresented: $showPlayer) }
            .task { await player.observeTimeline() }
            .task { await load() }
            .onAppear { updateAntigravityLifecycle() }
            .onChange(of: scenePhase) { _, _ in updateAntigravityLifecycle() }
            .onChange(of: showSettings) { _, _ in updateAntigravityLifecycle() }
            .onChange(of: showWaveSettings) { _, _ in updateAntigravityLifecycle() }
            .onChange(of: showPlayer) { _, _ in updateAntigravityLifecycle() }
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShakeNotification)) { _ in
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
            onToggleWave: toggleWave,
            onShakeWave: { triggerShakeWave() },
            isWaveShaking: isWaveShaking
        )
    }

    private var quickDestinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
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

    /// Логика встряхивания «Моей волны» (переключение на «Незнакомое», кинетический переход «Антигравити» и свежий поток)
    private func triggerShakeWave(forceDiscover: Bool = true) {
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

    private func updateAntigravityLifecycle() {
        antigravity.updateLifecycle(
            isAppActive: scenePhase == .active,
            isModalActive: showSettings || showWaveSettings || showPlayer
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
