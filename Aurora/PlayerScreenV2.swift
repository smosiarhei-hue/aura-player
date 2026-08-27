import SwiftUI
import UIKit

// MARK: - Sonivo Full Player

struct PlayerScreenV2: View {
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared
    @State private var analyzer = SpectrumAnalyzer.shared
    @State private var settings = SettingsStore.shared
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragY: CGFloat = 0
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var showArtistChoice = false
    @State private var resolvingArtist = false
    @State private var dismissing = false

    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showEqualizer = false
    @State private var showSleepTimer = false
    @State private var showSettings = false

    @State private var previewLyrics: Lyrics?
    @State private var lyricsLoading = false

    @State private var buildingTrackWave = false
    @State private var trackWaveReady = false
    @State private var trackWaveMessage: String?

    private var track: Track? { player.currentTrack }
    private var palette: [Color] { track?.palette ?? Palette.seeded(42).colors }
    private var beat: CGFloat {
        let source = max(analyzer.streamLevel, analyzer.bass, analyzer.level)
        return player.isPlaying ? CGFloat(min(max(source, 0), 1)) : 0
    }

    var body: some View {
        GeometryReader { geo in
            let coverSide = min(geo.size.width - 44, 390)

            ZStack {
                background

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.top, 8)

                        animatedCover(side: coverSide)
                            .padding(.top, 18)

                        metadata
                            .padding(.top, 24)

                        if settings.showTeleprompterInPlayer {
                            inlineLyrics
                                .padding(.top, 14)
                        }

                        scrubber
                            .padding(.top, 18)

                        controls
                            .padding(.top, 10)

                        featureDock
                            .padding(.top, 18)

                        transitionCard
                            .padding(.top, 12)

                        trackWaveCard
                            .padding(.top, 10)

                        Spacer(minLength: max(18, geo.safeAreaInsets.bottom))
                    }
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .offset(y: max(0, dragY))
            .scaleEffect(1 - min(max(dragY, 0) / 1800, 0.035), anchor: .bottom)
            .opacity(1 - min(max(dragY, 0) / 650, 0.22))
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden()
        .colorScheme(.dark)
        .interactiveDismissDisabled(dismissing)
        .confirmationDialog("Выберите исполнителя", isPresented: $showArtistChoice, titleVisibility: .visible) {
            ForEach(artistChoices) { artist in
                Button(artist.name) { selectedArtist = artist }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistView(artistId: artist.id) }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showLyrics) {
            LyricsSheetView()
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showQueue) {
            QueueSheetView()
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showEqualizer) {
            PlayerEQSheetView()
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerSheetView()
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(.dark)
        }
        .task(id: track?.id) {
            await loadLyricsPreview()
        }
        .onChange(of: track?.id) { _, _ in
            buildingTrackWave = false
            trackWaveReady = false
            trackWaveMessage = nil
        }
    }

    // MARK: Background

    private var background: some View {
        let colors = palette.isEmpty ? [AG.amber, AG.ember, Color.black] : palette
        let first = colors[0]
        let second = colors[min(1, colors.count - 1)]
        let third = colors[min(2, colors.count - 1)]
        let pulse = reduceMotion ? 0 : beat

        return ZStack {
            AG.bg

            RadialGradient(colors: [first.opacity(0.88), .clear], center: .topLeading, startRadius: 10, endRadius: 430)
                .scaleEffect(1 + pulse * 0.10, anchor: .topLeading)

            RadialGradient(colors: [second.opacity(0.72), .clear], center: .trailing, startRadius: 20, endRadius: 390)
                .scaleEffect(1 + pulse * 0.16, anchor: .trailing)
                .opacity(0.58 + pulse * 0.30)

            RadialGradient(colors: [third.opacity(0.58), AG.bg.opacity(0.92)], center: .bottomLeading, startRadius: 0, endRadius: 520)
                .scaleEffect(1 + pulse * 0.08, anchor: .bottomLeading)

            LinearGradient(colors: [.black.opacity(0.08), AG.bg.opacity(0.50), AG.bg.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: beat)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Header

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            VStack(spacing: 4) {
                Capsule().fill(.white.opacity(0.50)).frame(width: 36, height: 5)
                Text("СЕЙЧАС ИГРАЕТ")
                    .font(AG.text(9, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(width: 150, height: 44)
            .contentShape(Rectangle())
            .gesture(closeGesture)
            .accessibilityHint("Потяните вниз, чтобы свернуть")

            Spacer()

            Menu {
                Button { showLyrics = true } label: {
                    Label("Караоке", systemImage: "quote.bubble")
                }
                Button { showQueue = true } label: {
                    Label("Очередь", systemImage: "list.bullet")
                }
                Button { showEqualizer = true } label: {
                    Label("Эквалайзер", systemImage: "slider.vertical.3")
                }
                Button { showSleepTimer = true } label: {
                    Label("Таймер сна", systemImage: "timer")
                }
                Button { showSettings = true } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                Divider()
                Button(role: .destructive) {
                    player.stopAndClear()
                    close()
                } label: {
                    Label("Остановить и очистить", systemImage: "stop.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
        }
    }

    // MARK: Artwork and metadata

    private func animatedCover(side: CGFloat) -> some View {
        let pulse = reduceMotion ? 0 : beat
        return ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(AngularGradient(colors: [AG.amber, AG.ember, .clear, AG.amber], center: .center))
                .frame(width: side + 18, height: side + 18)
                .blur(radius: 18 + pulse * 8)
                .opacity(player.isPlaying ? 0.32 + pulse * 0.28 : 0.16)
                .scaleEffect(0.98 + pulse * 0.06)

            artwork
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.48), radius: 24, y: 15)
                .scaleEffect(player.isPlaying ? 1 : 0.975)
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: beat)
        .animation(.smooth(duration: 0.28), value: player.isPlaying)
        .id(track?.id)
        .transition(.opacity)
    }

    @ViewBuilder private var artwork: some View {
        if let track, let image = LibraryStore.cachedArtworkImage(for: track) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let cover = track?.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    fallbackArtwork
                }
            }
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 70, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var metadata: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(track?.title ?? "Sonivo")
                    .font(AG.display(24, .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: openArtist) {
                    HStack(spacing: 5) {
                        Text(track?.artist ?? "")
                            .font(AG.text(15, .semibold))
                            .lineLimit(1)
                        if resolvingArtist {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .black))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil || resolvingArtist)
            }

            if let track {
                Button { library.toggleFavorite(track) } label: {
                    Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Inline karaoke

    private var inlineLyrics: some View {
        Button { showLyrics = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "quote.bubble.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AG.amber)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.09), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("КАРАОКЕ")
                        .font(AG.text(9, .heavy))
                        .tracking(1.3)
                        .foregroundStyle(.white.opacity(0.54))

                    if lyricsLoading {
                        Text("Загрузка текста…")
                            .font(AG.text(14, .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    } else if let lines = activeLyricsLines {
                        Text(lines.current)
                            .font(AG.text(15, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        if let next = lines.next {
                            Text(next)
                                .font(AG.text(12, .medium))
                                .foregroundStyle(.white.opacity(0.44))
                                .lineLimit(1)
                        }
                    } else {
                        Text("Открыть текст песни")
                            .font(AG.text(14, .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .disabled(track == nil)
    }

    private var activeLyricsLines: (current: String, next: String?)? {
        guard let previewLyrics, !previewLyrics.lines.isEmpty else { return nil }
        if !previewLyrics.isSynchronized {
            return (previewLyrics.lines[0].text, previewLyrics.lines.dropFirst().first?.text)
        }

        let time = player.progress + settings.lyricsOffset
        let index = previewLyrics.lines.lastIndex(where: { $0.startTime <= time }) ?? 0
        let nextIndex = index + 1
        let next = nextIndex < previewLyrics.lines.count ? previewLyrics.lines[nextIndex].text : nil
        return (previewLyrics.lines[index].text, next)
    }

    private func loadLyricsPreview() async {
        previewLyrics = nil
        guard let requestedTrack = track else {
            lyricsLoading = false
            return
        }

        lyricsLoading = true
        let result = try? await LyricsService.shared.fetchLyrics(for: requestedTrack)
        guard player.currentTrack?.id == requestedTrack.id else { return }
        previewLyrics = result
        lyricsLoading = false
    }

    // MARK: Playback controls

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { player.progress }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.01)
            )
            .tint(.white)

            HStack {
                Text(player.formatted(player.progress))
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - player.progress)))
            }
            .font(AG.text(11, .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var controls: some View {
        HStack {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }

            Spacer()

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 31, weight: .black))
                    .foregroundStyle(.black.opacity(0.86))
                    .frame(width: 76, height: 76)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
                    .contentShape(Circle())
            }

            Spacer()

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: Feature controls

    private var featureDock: some View {
        HStack(spacing: 2) {
            featureButton(icon: "quote.bubble", title: "Текст", active: showLyrics) {
                showLyrics = true
            }

            VStack(spacing: 4) {
                AirPlayButtonView()
                    .frame(width: 44, height: 44)
                Text("AirPlay")
                    .font(AG.text(9, .semibold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity)

            featureButton(icon: "slider.vertical.3", title: "EQ", active: player.eqEnabled) {
                showEqualizer = true
            }

            featureButton(icon: "timer", title: "Таймер", active: player.sleepTimerMinutes != nil) {
                showSleepTimer = true
            }

            featureButton(icon: "list.bullet", title: "Очередь", active: showQueue) {
                showQueue = true
            }

            featureButton(icon: "gearshape", title: "Ещё", active: showSettings) {
                showSettings = true
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 0.8)
        }
    }

    private func featureButton(
        icon: String,
        title: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(active ? AG.amber : .white.opacity(0.84))
                    .frame(width: 44, height: 44)
                    .background(active ? AG.amber.opacity(0.14) : .clear, in: Circle())
                Text(title)
                    .font(AG.text(9, .semibold))
                    .foregroundStyle(active ? AG.amber : .white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transitionCard: some View {
        Menu {
            ForEach(TransitionMode.allCases) { mode in
                Button {
                    player.transitionMode = mode
                } label: {
                    if player.transitionMode == mode {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else {
                        Text(mode.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: player.transitionMode == .automix ? "waveform.path.ecg" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AG.amber)
                    .frame(width: 40, height: 40)
                    .background(AG.amber.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("ПЕРЕХОД МЕЖДУ ТРЕКАМИ")
                        .font(AG.text(9, .heavy))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.48))
                    Text(player.transitionMode.rawValue)
                        .font(AG.text(14, .bold))
                        .foregroundStyle(.white)
                    Text(player.transitionMode.description)
                        .font(AG.text(10, .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .padding(12)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.8)
            }
        }
    }

    private var trackWaveCard: some View {
        Button(action: startTrackWave) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 42, height: 42)
                    if buildingTrackWave {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(trackWaveReady ? "Волна по песне включена" : "Включить волну по этой песне")
                        .font(AG.text(14, .bold))
                        .foregroundStyle(.white)
                    Text(trackWaveMessage ?? "Gemini подберёт точное продолжение без повторов")
                        .font(AG.text(10.5, .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: trackWaveReady ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(trackWaveReady ? AG.amber : .white.opacity(0.72))
            }
            .padding(12)
            .background(AG.ember.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AG.amber.opacity(0.25), lineWidth: 0.8)
            }
        }
        .buttonStyle(.plain)
        .disabled(track == nil || buildingTrackWave)
    }

    // MARK: Actions

    private func startTrackWave() {
        guard let seed = track, !buildingTrackWave else { return }
        buildingTrackWave = true
        trackWaveReady = false
        trackWaveMessage = "Подбираем точное продолжение…"

        Task {
            let related = await YandexMusicService.shared.buildTrackWave(from: seed)
            guard player.currentTrack?.id == seed.id else {
                buildingTrackWave = false
                trackWaveMessage = nil
                return
            }

            guard !related.isEmpty else {
                buildingTrackWave = false
                trackWaveMessage = "Не удалось найти достаточно похожих песен"
                return
            }

            var seen = Set<UUID>([seed.id])
            let unique = related.filter { seen.insert($0.id).inserted }
            player.queue = [seed] + unique

            if let ymID = YandexMusicService.ymId(fromFileName: seed.fileName) {
                YandexMusicService.shared.beginStationSession("track:\(ymID)")
            }

            trackWaveReady = true
            buildingTrackWave = false
            trackWaveMessage = "В очереди: \(unique.count) похожих треков"
        }
    }

    private func togglePlayback() {
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.togglePlay()
    }

    private func previousTrack() {
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.previous()
    }

    private func nextTrack() {
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.next()
    }

    private func openArtist() {
        guard let track else { return }
        resolvingArtist = true
        Task {
            let resolved = await YandexMusicService.shared.resolvePlayerArtists(for: track)
            artistChoices = resolved
            resolvingArtist = false
            if resolved.count == 1 {
                selectedArtist = resolved[0]
            } else if resolved.count > 1 {
                showArtistChoice = true
            }
        }
    }

    private func close() {
        guard !dismissing else { return }
        dismissing = true
        isPresented = false
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragY = min(value.translation.height * 0.78, 180)
            }
            .onEnded { value in
                if value.translation.height > 70 || value.predictedEndTranslation.height > 125 {
                    close()
                } else {
                    withAnimation(.smooth(duration: 0.22)) {
                        dragY = 0
                    }
                }
            }
    }
}
