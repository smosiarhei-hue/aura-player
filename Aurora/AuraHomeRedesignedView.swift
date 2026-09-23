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
                MyWaveBackgroundVideoView(isPlaying: player.isPlaying)
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
                .refreshable { await load() }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showWaveSettings) { WaveVisualSettingsSheet() }
            .fullScreenCover(isPresented: $showPlayer) { PlayerScreenV2(isPresented: $showPlayer) }
            .task { await player.observeTimeline() }
            .task { await load() }
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
        VStack(spacing: 16) {
            Spacer(minLength: 160)

            Button(action: toggleWave) {
                HStack(spacing: 14) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .black))
                    Text("Моя волна")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 18, y: 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Запустить Мою волну")

            Button { showWaveSettings = true } label: {
                Label("Настроить", systemImage: "slider.horizontal.3")
                    .font(AG.text(.body, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 48)
                    .glassCapsule(interactive: true)
            }
            .buttonStyle(.plain)

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
        }
        .frame(minHeight: 440)
        .padding(.horizontal, 14)
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
            sectionTitle("Чарт", subtitle: "Главные треки сегодня")
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
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Премьера", subtitle: "Новая музыка для твоей волны")
            LazyVStack(spacing: 2) {
                ForEach(Array(newTracks.prefix(6))) { item in
                    AuraCatalogTrackRow(item: item, rank: nil) { SonivoPlay.track(item, in: newTracks) }
                }
            }.padding(.horizontal, 12)
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

    private func load() async {
        isLoading = true; loadError = nil
        do { chart = try await ym.getChart() }
        catch { chart = []; loadError = "Не удалось обновить чарт. Проверь подключение к Яндекс Музыке." }
        newTracks = await ym.getNewTracks(limit: 100)
        isLoading = false
    }
}

struct WaveVisualSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visuals.hdr.enabled") private var hdrEnabled = true
    @AppStorage("visuals.waveBeat.enabled") private var beatEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("HDR-блики", isOn: $hdrEnabled)
                    Toggle("Реакция на бас и kick", isOn: $beatEnabled)
                } header: {
                    Text("Визуализация")
                } footer: {
                    Text("HDR-блики повышают яркость только цветных светлых областей. Реакция использует низкие частоты примерно 30–120 Гц, а не вокал.")
                }
                Section("Предпросмотр") {
                    MyWaveBackgroundVideoView(isPlaying: true)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
            }
            .navigationTitle("Моя волна")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}
