import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation
import AVKit
import Combine

struct PlayerScreenV2: View {
    @State private var player = ActivePlayerPresentation()
    @State private var library = LibraryStore.shared
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeModal: ActivePlayerModal?
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var resolvingArtist = false
    @State private var showLyricsMode = false
    @State private var lyricsControlsVisible = false
    @State private var lyricsControlsHideTask: Task<Void, Never>?
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var coverDragX: CGFloat = 0
    @State private var dismissOffsetY: CGFloat = 0
    @State private var isCoverSwitching = false
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String?
    @State private var trackWaveTask: Task<Void, Never>?
    @State private var trackWaveRequestID = UUID()
    @State private var videoShotURL: URL?
    @State private var isVideoShotEnabled = UserDefaults.standard.object(forKey: "sonivo_videoshot_enabled") as? Bool ?? false
    @State private var videoLooperPlayer: AVQueuePlayer?
    @State private var videoLooper: AVPlayerLooper?
    @State private var videoShotTrackID: UUID?
    @ObservedObject private var aiVideoShotService = AIVideoShotGeneratorService.shared
    @State private var artworkPaletteColors: [Color] = []
    @State private var resolvedArtworkPaletteTrackID: UUID?
    @State private var paletteTrackId: UUID?
    @State private var artworkTrackId: UUID?
    @State private var currentArtworkImage: UIImage?
    @State private var cachedPhrases: [LyricPhrase] = []
    @State private var spectrum = SpectrumAnalyzer.shared
    private let tapSide: CGFloat = SN.tapTarget

    private var kickEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicKick, gain: 1.32)
    }

    private var bassEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicBass, gain: 1.18)
    }

    private var beatPulse: CGFloat {
        max(kickEnergy, bassEnergy * 0.85)
    }

    private var midEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicMids, gain: 1.22)
    }

    private var highEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicHighs, gain: 1.28)
    }

    private var fullSpectrumEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicLevel, gain: 1.16)
    }

    private func boostedVisualEnergy(_ raw: Float, gain: Double) -> CGFloat {
        let normalized = max(0, min(1, Double(raw)))
        // Lift quiet musical detail without crushing louder transients.
        return CGFloat(min(1, pow(normalized, 0.62) * gain))
    }

    enum ActivePlayerModal: String, Identifiable {
        case queue, equalizer, sleepTimer, settings, quality, artistSelection, lyrics
        var id: String { rawValue }
    }

    enum PlayerViewMode: Equatable {
        case standard
        case lyrics
        case karaoke
    }

    var playerViewMode: PlayerViewMode {
        if activeModal == .lyrics { return .karaoke }
        if showLyricsMode { return .lyrics }
        return .standard
    }

    var isVocalToggleVisible: Bool {
        playerViewMode == .lyrics || playerViewMode == .karaoke
    }

    init(isPresented: Binding<Bool>) { _isPresented = isPresented }
    private var track: Track? { player.displayTrack }
    private var palette: [Color] {
        if !artworkPaletteColors.isEmpty { return artworkPaletteColors }
        if let colors = track?.palette, !colors.isEmpty { return colors }
        return Palette.seeded(42).colors
    }

    var body: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let totalWidth = geo.size.width
            let topInset = max(geo.safeAreaInsets.top, 50)
            let standardArtworkStageHeight = isFullScreenVideoShot
                ? (totalHeight * 0.55)
                : min(totalWidth - 40, totalHeight * 0.44)

            let isPullingDown = dismissOffsetY > 0
            let dismissScale = reduceMotion ? 1.0 : max(0.88, 1.0 - (dismissOffsetY / totalHeight) * 0.14)
            let dismissCorner = max(0.0, min(42.0, (dismissOffsetY / 120.0) * 42.0))

            ZStack(alignment: .top) {
                background
                    .frame(width: totalWidth, height: totalHeight)
                    .clipped()

                if showLyricsMode {
                    lyricsPlayerLayout(
                        width: totalWidth,
                        height: totalHeight,
                        topInset: topInset,
                        safeAreaBottom: geo.safeAreaInsets.bottom
                    )
                    .transition(.opacity)
                    .zIndex(2)
                } else {
                    VStack(spacing: 0) {
                        topHeader
                            .padding(.top, topInset)
                            .padding(.horizontal, 20)
                            // Dismiss only from the header; a content scroll must not close the player.
                            .simultaneousGesture(playerDismissGesture)
                            .zIndex(3)

                        ScrollView(.vertical) {
                            VStack(spacing: 0) {
                                artworkStage(width: totalWidth, height: standardArtworkStageHeight)
                                    .frame(width: totalWidth, height: standardArtworkStageHeight)
                                    .padding(.top, 12)
                                lowerDeck(safeAreaBottom: geo.safeAreaInsets.bottom)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.hidden)
                        .accessibilityLabel("Плеер и дополнительные действия")
                    }
                    .transition(.opacity)
                }

                // Native Apple Smooth Ambient Vignette under Dynamic Island / Status Bar
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.85),
                        Color.black.opacity(0.40),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: topInset + 40)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
            .frame(width: totalWidth, height: totalHeight, alignment: .top)
            .animation(SN.slowSpring, value: showLyricsMode)
            .offset(y: dismissOffsetY)
            .scaleEffect(dismissScale, anchor: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: dismissCorner, style: .continuous))
            .shadow(color: Color.black.opacity(isPullingDown ? 0.35 : 0.0), radius: 24, y: 12)
        }
        .ignoresSafeArea()
        .background(SN.bg.ignoresSafeArea())
        .sheet(item: $activeModal) { modal in
            NavigationStack {
                switch modal {
                case .queue: QueueSheetView()
                case .equalizer: PlayerEQSheetView()
                case .sleepTimer: SleepTimerSheetView()
                case .settings: SettingsView()
                case .quality: PlayerQualityModalView(player: player, onDismiss: { activeModal = nil })
                case .artistSelection: artistSelectionSheet
                case .lyrics:
                    LyricsView(lyrics: lyrics, isLoading: lyricsLoading, player: player)
                        .navigationTitle("Текст песни").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
                }
            }
        }
        .sheet(item: $selectedArtist) { artist in NavigationStack { ArtistView(artistId: artist.id) } }
        .task { await player.observeTimeline() }
        .task(id: track?.id) {
            async let p: () = refreshPalette()
            async let l: () = loadLyrics()
            async let v: () = loadVideoShot()
            _ = await (p, l, v)
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            isCoverSwitching = false
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                videoLooperPlayer?.play()
            } else {
                videoLooperPlayer?.pause()
            }
        }
        .onChange(of: track?.id) { _, _ in
            trackWaveTask?.cancel()
            trackWaveRequestID = UUID()
            waveLoading = false
            waveMessage = nil
            lyrics = nil
            cachedPhrases = []
            lyricsLoading = true
            videoShotURL = nil
            videoShotTrackID = nil
            teardownVideoLooper()
        }
        .onChange(of: showLyricsMode) { _, isEnabled in
            lyricsControlsHideTask?.cancel()
            lyricsControlsVisible = false
            coverDragX = 0
            dismissOffsetY = 0
            if !isEnabled {
                activeModal = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didUpdateCustomLyrics)) { _ in
            Task { await loadLyrics() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .didGenerateAIVideoShot)) { note in
            if let targetUUID = note.object as? UUID, targetUUID == track?.id,
               let targetURL = note.userInfo?["url"] as? URL {
                videoShotURL = targetURL
                videoShotTrackID = targetUUID
                if isVideoShotEnabled {
                    setupVideoLooper(url: targetURL)
                }
            }
        }
        .onChange(of: player.incomingTrack?.id) { _, _ in
            if let outgoing = player.currentTrack, let incoming = player.incomingTrack {
                AIDJService.shared.prefetchCommentaryIfNeeded(outgoing: outgoing, incoming: incoming)
            }
        }
        .onDisappear {
            trackWaveTask?.cancel()
            trackWaveRequestID = UUID()
            waveLoading = false
            teardownVideoLooper()
        }
    }

    private var playerDismissGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.25,
                      !showLyricsMode else { return }
                dismissOffsetY = value.translation.height
            }
            .onEnded { value in
                guard dismissOffsetY > 0 else { return }
                if value.translation.height > 110 || value.predictedEndTranslation.height > 240 {
                    close()
                } else {
                    withAnimation(reduceMotion ? nil : SN.spring) { dismissOffsetY = 0 }
                }
            }
    }

    private var isFullScreenVideoShot: Bool {
        isVideoShotEnabled && videoShotTrackID == track?.id && videoLooperPlayer != nil && !showLyricsMode
    }

    private var background: some View {
        ZStack {
            if isFullScreenVideoShot {
                // Размытый атмосферный фон на весь экран (ambient blur по краям)
                if let videoLooperPlayer {
                    VideoShotPlayerView(player: videoLooperPlayer, videoGravity: .resizeAspectFill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaledToFill()
                        .blur(radius: 12)
                        .scaleEffect(1.08)
                        .opacity(0.35)
                        .clipped()
                        .ignoresSafeArea()
                } else if let img = (artworkTrackId == track?.id ? currentArtworkImage : nil) ?? track.flatMap({ LibraryStore.cachedArtworkImage(for: $0) }) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .blur(radius: 14)
                        .scaleEffect(1.10)
                        .opacity(0.30)
                        .clipped()
                        .ignoresSafeArea()
                }

                // Четкое видео 1080x1920 (9:16) от лейбла без обрезки по бокам и без искусственного зума
                if let videoLooperPlayer {
                    VideoShotPlayerView(player: videoLooperPlayer, videoGravity: .resizeAspect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                }

                // Элегантная кинематографичная виньетка:
                // Верх — легкое затемнение под хедер; центр — кристально чистое видео; низ — мягкое затемнение под контролы
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.40), location: 0.0),
                    .init(color: .black.opacity(0.10), location: 0.18),
                    .init(color: .clear, location: 0.32),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.22), location: 0.72),
                    .init(color: .black.opacity(0.50), location: 0.88),
                    .init(color: .black.opacity(0.68), location: 1.0)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            } else if reduceMotion || scenePhase != .active {
                gradientBackground
                LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0),
                                        .init(color: .black.opacity(0.45), location: 0.70),
                                        .init(color: .black.opacity(0.75), location: 1)],
                                startPoint: .top, endPoint: .bottom)
            } else {
                PlayerMusicReactiveBackdrop(
                    artwork: currentArtworkImage ?? track.flatMap { LibraryStore.cachedArtworkImage(for: $0) },
                    palette: backgroundColors,
                    kick: kickEnergy,
                    bass: bassEnergy,
                    mids: midEnergy,
                    highs: highEnergy,
                    level: fullSpectrumEnergy,
                    isPlaying: player.isPlaying,
                    reduceMotion: reduceMotion
                )
            }
        }.allowsHitTesting(false)
    }
    private var backgroundColors: [Color] { palette.isEmpty ? [SN.amber, SN.ember] : palette }
    private var gradientBackground: some View {
        let colors = backgroundColors
        return LinearGradient(colors: [colors[0].opacity(0.65), colors[min(1, colors.count - 1)].opacity(0.38), .black],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var topHeader: some View {
        HStack {
            Button {
                Haptics.tap(.light)
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))

            Spacer()

            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)

            Spacer()

            moreMenuButton
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    private func lyricsPlayerLayout(
        width: CGFloat,
        height: CGFloat,
        topInset: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            lyricsTopHeader
                .padding(.top, topInset)
                .padding(.horizontal, 20)

            compactLyricsMetadata
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 6)

            inlineLyricsStage(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleLyricsControls()
                }

            if lyricsControlsVisible {
                lyricsControlsDeck(safeAreaBottom: safeAreaBottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Color.clear
                    .frame(height: max(safeAreaBottom, 12))
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .animation(SN.spring, value: lyricsControlsVisible)
    }

    private var lyricsTopHeader: some View {
        HStack {
            Button {
                Haptics.tap(.light)
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))

            Spacer()

            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
    }

    private var compactLyricsMetadata: some View {
        let current = track
        return HStack(spacing: 16) {
            artwork
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.30), radius: 12, y: 6)

            Button(action: openArtist) {
                VStack(alignment: .leading, spacing: 4) {
                    MarqueeText(
                        text: current?.title ?? "Не играет",
                        font: SN.rounded(.title2, .bold),
                        color: SN.ink,
                        height: 30
                    )
                    MarqueeText(
                        text: current?.artist ?? "",
                        font: SN.rounded(.body, .medium),
                        color: SN.inkMuted,
                        height: 24
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(current == nil || resolvingArtist)

            Button {
                guard let current else { return }
                Haptics.tap(.medium)
                library.toggleFavorite(current)
            } label: {
                let favorite = current.map(library.isTrackFavorite) ?? false
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(favorite ? SN.amber : SN.ink)
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))
            .disabled(current == nil)

            moreMenuButton
        }
        .frame(maxWidth: .infinity)
    }

    private func lyricsControlsDeck(safeAreaBottom: CGFloat) -> some View {
        VStack(spacing: 16) {
            PlayerTimelineSection(player: player) { centerStatusLabel }
            transportControls
            FluidVolumeSlider()
                .accessibilityElement(children: .contain)

            HStack(spacing: 0) {
                GlassIconButton(
                    systemImage: "quote.bubble.fill",
                    tint: SN.amber,
                    accessibilityLabel: "Вернуться к обычному плееру"
                ) {
                    Haptics.tap(.light)
                    withAnimation(SN.slowSpring) {
                        showLyricsMode = false
                    }
                }
                .frame(maxWidth: .infinity)

                AirPlayButtonView()
                    .frame(width: tapSide, height: tapSide)
                    .glassCircle()
                    .frame(maxWidth: .infinity)

                GlassIconButton(
                    systemImage: "list.bullet",
                    tint: SN.inkMuted,
                    accessibilityLabel: "Очередь"
                ) {
                    openModal(.queue)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, max(safeAreaBottom, 16))
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.48), Color.black.opacity(0.76)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func artworkStage(width: CGFloat, height: CGFloat) -> some View {
        let cardSide = min(width - 40, height)
        let tiltAngle = reduceMotion ? 0.0 : Double(coverDragX / width) * 4.0
        let dragScale = reduceMotion ? 1.0 : (1.0 - min(0.06, abs(coverDragX / width) * 0.06))

        return ZStack {
            if isFullScreenVideoShot {
                // В полноэкранном режиме видеошота обложка не закрывает видео даже при включении текста!
                Color.clear
                    .frame(width: width, height: height)
            } else {
                artwork
                    .frame(width: cardSide, height: cardSide)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect((player.isPlaying ? 1.0 : 0.96) * dragScale)
        .offset(x: coverDragX)
        .rotationEffect(.degrees(tiltAngle))
        .contentShape(Rectangle())
        .gesture(
            showLyricsMode ? nil : DragGesture(minimumDistance: 15)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    coverDragX = value.translation.width
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { coverDragX = 0 }
                        return
                    }
                    let threshold: CGFloat = 55
                    let projected = value.predictedEndTranslation.width
                    if (value.translation.width < -threshold || projected < -100), !isCoverSwitching {
                        Haptics.tap(.light)
                        nextTrack()
                        coverDragX = width * 0.40
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                            coverDragX = 0
                        }
                    } else if (value.translation.width > threshold || projected > 100), !isCoverSwitching {
                        Haptics.tap(.light)
                        previousTrack()
                        coverDragX = -width * 0.40
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                            coverDragX = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { coverDragX = 0 }
                    }
                }
        )
        .animation(SN.slowSpring, value: player.isPlaying)
        .animation(SN.slowSpring, value: showLyricsMode)
    }

    @ViewBuilder
    private func inlineLyricsStage(width: CGFloat, height: CGFloat) -> some View {
        let settings = SettingsStore.shared
        let playbackTime = LyricsPlaybackClock.time(for: player, offset: settings.lyricsOffset)
        let textLift = min(72, height * 0.09)

        VStack(spacing: 0) {
            if lyricsLoading {
                Spacer()
                ProgressView()
                    .tint(.white)
                Text("Загрузка текста…")
                    .font(SN.text(.subheadline, .medium))
                    .foregroundStyle(.white.opacity(0.70))
                Spacer()
            } else if let lyrics, !lyrics.lines.isEmpty {
                if settings.lyricsDesign == .staggered {
                    StaggeredLyricsView(lyrics: lyrics, player: player, showsSource: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -textLift)
                } else if lyrics.hasDynamicWordTimings {
                    KineticLyricsView(
                        phrases: cachedPhrases.isEmpty ? LyricPhrase.from(lines: lyrics.lines) : cachedPhrases,
                        currentTime: .constant(playbackTime),
                        isPlaying: player.isPlaying,
                        fontSize: max(30, settings.lyricsFontSize * 0.82)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 22)
                    .offset(y: -textLift)
                } else {
                    CoverLyricsScrollView(
                        lyrics: lyrics,
                        player: player,
                        side: min(width - 24, height - 20)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -textLift)
                }
            } else {
                Spacer()
                Image(systemName: "quote.bubble")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.40))
                Text("Текст песни отсутствует")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func toggleLyricsControls() {
        lyricsControlsHideTask?.cancel()

        if lyricsControlsVisible {
            withAnimation(SN.spring) {
                lyricsControlsVisible = false
            }
            return
        }

        withAnimation(SN.spring) {
            lyricsControlsVisible = true
        }
        lyricsControlsHideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(SN.spring) {
                    lyricsControlsVisible = false
                }
            }
        }
    }

    private func lyricsCoverCard(side: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            // 1. Матовая подложка с мягким размытием обложки в цветах трека (стиль Яндекс Музыки)
            ZStack {
                if let primary = artworkPaletteColors.first ?? palette.first {
                    primary.opacity(0.38)
                } else {
                    Color(red: 0.31, green: 0.35, blue: 0.38)
                }
                artwork
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .blur(radius: 24)
                    .scaleEffect(1.15)
                    .opacity(0.55)
                    .clipped()

                Color.black.opacity(0.28)
            }

            // 2. Сцена отображения текста (крупный жирный центрированный шрифт)
            VStack(spacing: 0) {
                if lyricsLoading {
                    Spacer()
                    ProgressView().tint(.white)
                    Text("Загрузка текста…")
                        .font(SN.text(.subheadline, .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 8)
                    Spacer()
                } else if let lyrics, !lyrics.lines.isEmpty {
                    CoverLyricsScrollView(
                        lyrics: lyrics,
                        player: player,
                        side: side
                    )
                } else {
                    let pair = currentLyricsPair
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(pair.current.isEmpty || pair.current == "Слова песни" ? "Текст песни отсутствует" : pair.current)
                            .font(.system(size: 32, weight: .heavy, design: .default))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .minimumScaleFactor(0.70)
                            .padding(.horizontal, 20)
                            .shadow(color: .black.opacity(0.45), radius: 3, y: 1.5)
                        if let next = pair.next {
                            Text(next)
                                .font(.system(size: 24, weight: .bold, design: .default))
                                .foregroundStyle(.white.opacity(0.35))
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.70)
                                .padding(.horizontal, 20)
                        }
                    }
                    Spacer()
                }
            }
            .frame(width: side, height: side)

            // 3. Минималистичная иконка «Развернуть» в верхнем правом углу обложки
            Button {
                openModal(.lyrics)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.94))
            .padding(10)
            .accessibilityLabel("Развернуть текст песни на весь экран")

            // 4. Оверлей управления вокалом (караоке-режим / Apple Music Sing style)
            if isVocalToggleVisible {
                VocalIsolationControlView()
                    .padding(VocalIsolationUIConfig.cornerPadding)
                    .frame(maxWidth: side, maxHeight: side, alignment: VocalIsolationUIConfig.cornerAlignment)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private var currentLyricsPair: (current: String, next: String?) {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return ("Слова песни", nil) }
        let targetTime = LyricsPlaybackClock.time(for: player, offset: SettingsStore.shared.lyricsOffset)
        var lineIndex = 0
        for (i, line) in lines.enumerated() { if line.startTime <= targetTime { lineIndex = i } else { break } }
        return (lines[lineIndex].text, lineIndex + 1 < lines.count ? lines[lineIndex + 1].text : nil)
    }

    @ViewBuilder private var artwork: some View {
        let cached = track.flatMap { LibraryStore.cachedArtworkImage(for: $0) }
        let current = (artworkTrackId == track?.id ? currentArtworkImage : nil) ?? cached
        if let current {
            Image(uiImage: current)
                .resizable()
                .scaledToFit()
                .id(track?.id)
        } else if let raw = track?.coverURL, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit() } else { fallbackArtwork }
            }
            .id(track?.id)
        } else {
            fallbackArtwork
                .id(track?.id)
        }
    }
    private var fallbackArtwork: some View {
        ZStack { LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.system(size: 70, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
    }

    private func lowerDeck(safeAreaBottom: CGFloat) -> some View {
        VStack(spacing: 14) {
            metadataRow
            PlayerTimelineSection(player: player) { centerStatusLabel }
            transportControls
            FluidVolumeSlider()
                .accessibilityElement(children: .contain)

            trackWaveButton

            if let waveMessage {
                Text(waveMessage)
                    .font(SN.text(.caption, .semibold))
                    .foregroundStyle(SN.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Действия ниже", systemImage: "chevron.down")
                .font(SN.text(.caption, .medium))
                .foregroundStyle(SN.inkMuted)
                .padding(.top, 4)
            secondaryPlayerActions
                .padding(.top, 24)

        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, max(safeAreaBottom, 20))
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(0.50))
                Color.black.opacity(0.35)
                if let tint = palette.first {
                    tint.opacity(0.08)
                }
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.12),
                        .init(color: .black.opacity(0.40), location: 0.35),
                        .init(color: .black.opacity(0.80), location: 0.65),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var trackWaveButton: some View {
        let catalogTrack = track.flatMap { YandexMusicService.ymId(fromFileName: $0.fileName) } != nil
        let station = YandexMusicService.shared.activeStationId
        let isTrackRadio = station?.hasPrefix("track:") == true
        // Only a palette extracted from this track's actual cover may tint the button.
        let coverColors = resolvedArtworkPaletteTrackID == track?.id ? artworkPaletteColors : []
        let glassTint = coverColors.first?.opacity(0.12) ?? Color.clear
        return Button(action: startTrackWave) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(SN.text(.title2, .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(waveLoading ? "Настраиваем волну…" : "Моя волна по текущему треку")
                        .font(SN.text(.headline, .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !catalogTrack {
                        Text("Недоступна для этого трека")
                            .font(SN.text(.caption, .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if waveLoading {
                    ProgressView().tint(SN.ink)
                } else {
                    Image(systemName: isTrackRadio ? "checkmark" : "arrow.right")
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(SN.ink)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .glassEffect(.regular.tint(glassTint).interactive(), in: .rect(cornerRadius: SN.radius))
            .background {
                // A transparent moving tint sits behind the system glass, not a painted card.
                PlayerTrackWaveBackdrop(colors: coverColors, isPlaying: player.isPlaying)
                    .clipShape(RoundedRectangle(cornerRadius: SN.radius, style: .continuous))
            }
            .contentShape(RoundedRectangle(cornerRadius: SN.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!catalogTrack || waveLoading)
        .opacity(catalogTrack ? 1 : 0.55)
        .accessibilityLabel("Моя волна по текущему треку")
        .accessibilityValue(waveLoading ? "Загрузка рекомендаций" : (isTrackRadio ? "Волна по треку активна" : "Не запущена"))
        .accessibilityHint("Заменяет следующие треки волной по текущей песне, не прерывая её")
    }

    private var secondaryPlayerActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Дополнительно")
                .font(SN.text(.caption, .semibold))
                .foregroundStyle(SN.inkMuted)
            // Existing native actions remain below the primary track-wave button.
            HStack(spacing: 0) {
                GlassIconButton(
                    systemImage: showLyricsMode ? "quote.bubble.fill" : "quote.bubble",
                    tint: showLyricsMode ? SN.amber : SN.inkMuted,
                    accessibilityLabel: "Текст песни"
                ) {
                    withAnimation(SN.spring) { showLyricsMode.toggle() }
                }
                .frame(maxWidth: .infinity)

                AirPlayButtonView()
                    .frame(width: tapSide, height: tapSide)
                    .glassCircle()
                    .frame(maxWidth: .infinity)

                sleepTimerBottomButton
                    .frame(maxWidth: .infinity)

                GlassIconButton(
                    systemImage: "slider.vertical.3",
                    tint: player.eqEnabled ? SN.amber : SN.inkMuted,
                    accessibilityLabel: "Эквалайзер"
                ) {
                    openModal(.equalizer)
                }
                .frame(maxWidth: .infinity)

                GlassIconButton(
                    systemImage: "list.bullet",
                    tint: SN.inkMuted,
                    accessibilityLabel: "Очередь"
                ) {
                    openModal(.queue)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var sleepTimerBottomButton: some View {
        Button {
            Haptics.tap(.light)
            openModal(.sleepTimer)
        } label: {
            if let timerText = player.sleepTimerFormatted {
                HStack(spacing: 5) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(timerText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.18))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.orange.opacity(0.50), lineWidth: 1)
                        )
                        .shadow(color: Color.orange.opacity(0.28), radius: 8, y: 0)
                )
            } else {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(SN.inkMuted)
                    .frame(width: tapSide, height: tapSide)
                    .glassCircle()
            }
        }
        .buttonStyle(TactileButtonStyle(scale: 0.92))
        .accessibilityLabel((player.sleepTimerRemaining ?? 0) > 0 ? "Таймер сна активен: \(player.sleepTimerFormatted ?? "")" : "Таймер сна")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: (player.sleepTimerRemaining ?? 0) > 0)
    }

    private var metadataRow: some View {
        let current = track
        return HStack(alignment: .center, spacing: 14) {
            Button(action: openArtist) {
                VStack(alignment: .leading, spacing: 3) {
                    MarqueeText(
                        text: current?.title ?? "Не играет",
                        font: SN.rounded(.title2, .bold),
                        color: SN.ink,
                        height: 28
                    )
                    MarqueeText(
                        text: current?.artist ?? "",
                        font: SN.rounded(.body, .medium),
                        color: SN.inkMuted,
                        height: 22
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(current == nil || resolvingArtist)

            HStack(spacing: 8) {
                Button {
                    guard let current else { return }
                    Haptics.tap(.medium)
                    library.toggleFavorite(current)
                } label: {
                    let favorite = current.map(library.isTrackFavorite) ?? false
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(favorite ? SN.amber : SN.inkMuted)
                        .symbolEffect(.bounce, value: favorite)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: tapSide, height: tapSide)
                        .glassCircle()
                }
                .buttonStyle(TactileButtonStyle(scale: 0.90))
                .disabled(current == nil)
                .accessibilityLabel(current.map(library.isTrackFavorite) == true ? "Убрать из избранного" : "В избранное")

                moreMenuButton
            }
        }
    }
    @ViewBuilder private var centerStatusLabel: some View {
        if aiVideoShotService.isGenerating && aiVideoShotService.currentTrackId == track?.id.uuidString {
            HStack(spacing: 5) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: SN.accent))
                    .scaleEffect(0.65)
                Text(aiVideoShotService.statusMessage)
                    .font(SN.text(.caption2, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassCapsule(interactive: false)
            .transition(.opacity)
        } else if player.isTransitionActive {
            AIDJTransitionBadgeView(incomingTrack: player.incomingTrack)
                .transition(.opacity)
        } else {
            qualityBadgeButton
                .transition(.opacity)
        }
    }
    private var qualityBadgeButton: some View {
        Button {
            Haptics.tap(.light)
            openModal(.quality)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: qualityBadgeIcon)
                    .font(.system(size: 10, weight: .semibold))
                Text(qualityBadgeLabel)
                    .font(SN.text(.caption2, .semibold))
            }
            .foregroundStyle(SN.ink.opacity(0.50))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
    private var qualityBadgeIcon: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        if codec.contains("atmos") {
            return "dot.radiowaves.left.and.right"
        }
        return "waveform"
    }
    private var qualityBadgeLabel: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("atmos") {
            return "Dolby Atmos"
        }
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") || bitrate >= 1000 {
            return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"
        }
        if bitrate >= 320 { return "HQ \(bitrate) kbps" }
        if bitrate > 0 { return "\(bitrate) kbps" }
        if !codec.isEmpty { return codec.uppercased() }
        return player.audioQuality.badgeText
    }
    private var transportControls: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap(.light)
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.shuffle ? SN.amber : SN.inkMuted)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(player.shuffle ? "Перемешивание включено" : "Перемешать")

            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }

            Button(action: togglePlayback) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 70, height: 70)
                        .shadow(color: .white.opacity(0.20), radius: 14, y: 4)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.92))
                        .offset(x: player.isPlaying ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace.byLayer))
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(player.isLoading)

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }

            Button {
                Haptics.tap(.light)
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode != .off ? SN.amber : SN.inkMuted)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Повтор")
        }
        .foregroundStyle(SN.ink)
        .buttonStyle(TactileButtonStyle(scale: 0.94))
    }

    private var moreMenuButton: some View {
        Menu {
            if let current = track {
                Section {
                    let disliked = UserTasteEngine.shared.isDisliked(track: current)
                    Button(role: disliked ? nil : .destructive) {
                        if disliked {
                            UserTasteEngine.shared.removeDislike(track: current)
                            waveMessage = "Трек снова может появиться в волне"
                        } else {
                            UserTasteEngine.shared.recordDislike(track: current)
                            MoodRadioEngine.shared.recordFeedback(track: current, action: .dislike)
                            waveMessage = "Трек исключён из Моей волны"
                            player.next()
                        }
                    } label: {
                        Label(
                            disliked ? "Отменить дизлайк" : "Не рекомендовать этот трек",
                            systemImage: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                        )
                    }
                }
            }

            Section {
                Button {
                    startAIVibeWave()
                } label: {
                    Label("AI Вайб-волна (похожие по вайбу)", systemImage: "sparkles")
                }
                .disabled(track == nil || waveLoading || AIDJService.shared.isVibeWaveGenerating)

                if videoShotURL != nil {
                    Button {
                        toggleVideoShot()
                    } label: {
                        Label(
                            isVideoShotEnabled ? "Скрыть видео-шот" : "Показать видео-шот",
                            systemImage: isVideoShotEnabled ? "eye.slash" : "eye"
                        )
                    }

                    Button {
                        generateAIVideoShot(forceRegenerate: true)
                    } label: {
                        Label("Перегенерировать AI Видео-шот (новый вайб)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(track == nil || aiVideoShotService.isGenerating)

                    Button(role: .destructive) {
                        deleteCurrentVideoShot()
                    } label: {
                        Label("Удалить видео-шот", systemImage: "trash")
                    }
                } else {
                    Button {
                        generateAIVideoShot()
                    } label: {
                        Label("Создать AI Видео-шот (MiniMax H3)", systemImage: "sparkles.tv")
                    }
                    .disabled(track == nil || aiVideoShotService.isGenerating)
                }
            }

            Section {
                Button {
                    SettingsStore.shared.isNeuralEngineEnabled.toggle()
                    waveMessage = SettingsStore.shared.isNeuralEngineEnabled ? "🧠 Apple Neural Engine включён" : "🧠 Apple Neural Engine выключен"
                    Task {
                        try? await Task.sleep(for: .seconds(2.0))
                        waveMessage = nil
                    }
                    Task { await loadLyrics() }
                } label: {
                    Label(
                        SettingsStore.shared.isNeuralEngineEnabled ? "Neural Engine: Включён" : "Neural Engine: Выключен",
                        systemImage: SettingsStore.shared.isNeuralEngineEnabled ? "brain.fill" : "brain"
                    )
                }
            }

            Section {
                Button { withAnimation(SN.spring) { showLyricsMode.toggle() } } label: {
                    Label("Текст песни", systemImage: "quote.bubble")
                }

                Menu {
                    Button {
                        SettingsStore.shared.lyricsOffset -= 0.25
                        showOffsetMessage()
                    } label: {
                        Label("Текст спешит (-0.25 с)", systemImage: "minus.circle")
                    }
                    Button {
                        SettingsStore.shared.lyricsOffset += 0.25
                        showOffsetMessage()
                    } label: {
                        Label("Текст отстаёт (+0.25 с)", systemImage: "plus.circle")
                    }
                    Button {
                        SettingsStore.shared.lyricsOffset = 0.0
                        showOffsetMessage()
                    } label: {
                        Label("Сброс на 0.0 с", systemImage: "arrow.uturn.backward")
                    }
                } label: {
                    let ms = Int(SettingsStore.shared.lyricsOffset * 1000)
                    let sign = ms > 0 ? "+" : ""
                    Label("Синхронизация текста (\(sign)\(ms) мс)", systemImage: "clock.arrow.circlepath")
                }

                Button { openModal(.queue) } label: {
                    Label("Очередь", systemImage: "list.bullet")
                }
                Button { openModal(.equalizer) } label: {
                    Label("Эквалайзер", systemImage: "slider.vertical.3")
                }
                Button { openModal(.sleepTimer) } label: {
                    if let timerText = player.sleepTimerFormatted {
                        Label("Таймер сна (\(timerText))", systemImage: "moon.zzz.fill")
                    } else {
                        Label("Таймер сна", systemImage: "moon.zzz")
                    }
                }
                Button { openModal(.settings) } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
            }

            Section {
                Button {
                    Task {
                        if await SonivoDiagnostics.shared.sendReportToTelegram() {
                            waveMessage = "✅ Диагностика отправлена"
                            try? await Task.sleep(for: .seconds(2.5))
                            waveMessage = nil
                        }
                    }
                } label: {
                    Label("Отправить логи", systemImage: "paperplane")
                }

                Button(role: .destructive) {
                    player.stopAndClear()
                    close()
                } label: {
                    Label("Остановить и очистить", systemImage: "stop.fill")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(SN.inkMuted)
                .frame(width: tapSide, height: tapSide)
                .glassCircle()
        }
        .accessibilityLabel("Ещё")
    }

    private var artistSelectionSheet: some View {
        List(artistChoices) { artist in Button(artist.name) { activeModal = nil; selectedArtist = artist } }
            .navigationTitle("Исполнители").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
    }

    private func updatePalette(from image: UIImage, trackID: UUID) async {
        let hexes = await Task.detached(priority: .utility) { LibraryStore.artworkPalette(from: image) }.value
        guard !Task.isCancelled, track?.id == trackID, paletteTrackId == trackID else { return }
        let colors = hexes.compactMap(Color.init(hex:)); guard !colors.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.85)) {
            artworkPaletteColors = colors
            resolvedArtworkPaletteTrackID = trackID
        }
    }
    private func refreshPalette() async {
        guard let track, paletteTrackId != track.id || resolvedArtworkPaletteTrackID != track.id else { return }
        paletteTrackId = track.id
        artworkTrackId = track.id
        if let image = LibraryStore.cachedArtworkImage(for: track) {
            currentArtworkImage = image
            await updatePalette(from: image, trackID: track.id)
        } else if let raw = track.coverURL, let url = URL(string: raw), let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
            LibraryStore.cacheArtworkImage(image, for: track)
            if paletteTrackId == track.id {
                currentArtworkImage = image
                await updatePalette(from: image, trackID: track.id)
            }
        } else {
            currentArtworkImage = nil
            if !track.palette.isEmpty { artworkPaletteColors = track.palette }
        }
        prefetchUpcomingArtwork()
    }

    private func prefetchUpcomingArtwork() {
        let q = player.queue
        guard let current = track,
              let idx = q.firstIndex(where: { $0.id == current.id }) else { return }
        let nextTracks = Array(q.dropFirst(idx + 1).prefix(3))
        if let next = nextTracks.first {
            AIDJService.shared.prefetchCommentaryIfNeeded(outgoing: current, incoming: next)
        }
        for next in nextTracks {
            guard LibraryStore.cachedArtworkImage(for: next) == nil,
                  let raw = next.coverURL,
                  let url = URL(string: raw) else { continue }
            Task(priority: .utility) {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let img = UIImage(data: data) {
                    LibraryStore.cacheArtworkImage(img, for: next)
                }
            }
        }
    }

    private func loadLyrics() async {
        lyrics = nil
        cachedPhrases = []
        guard let requested = track else { lyricsLoading = false; return }
        let requestedId = requested.id
        lyricsLoading = true
        defer {
            if self.track?.id == requestedId {
                self.lyricsLoading = false
            }
        }

        // 1. Fetch official lyrics from all verified sources (Yandex Music, LRCLIB, Genius, ID3)
        let result = try? await LyricsService.shared.fetchLyrics(for: requested)
        guard !Task.isCancelled, self.track?.id == requestedId else { return }

        // Keep source timing exactly as returned. Plain text stays plain; no
        // duration-based karaoke and no automatically generated speech transcript.
        if let found = result, !found.lines.isEmpty {
            let verified = LyricsMatchPolicy.validatedTimings(found, duration: requested.duration)
            withAnimation(.spring(response: 0.40, dampingFraction: 0.85)) {
                self.lyrics = verified
                self.cachedPhrases = verified.isSynchronized ? LyricPhrase.from(lines: verified.lines) : []
            }
            return
        }

        // 4. No lyrics available anywhere
        guard !Task.isCancelled, self.track?.id == requestedId else { return }
        self.lyrics = nil
        self.cachedPhrases = []
    }
    private func loadVideoShot() async {
        videoShotURL = nil
        videoShotTrackID = nil
        teardownVideoLooper()
        guard isVideoShotEnabled, let track else { return }
        let requestedTrackID = track.id
        let id = PlayerCore.yandexTrackID(from: track)

        var url: URL? = nil

        // 1. ПРИОРИТЕТ 1: Локальный кэш устройства и встроенные видео в App Bundle (работает всегда 24/7 офлайн, когда ПК выключен)
        url = AIVideoShotGeneratorService.shared.localVideoShotURL(for: id, title: track.title, artist: track.artist)

        // 2. ПРИОРИТЕТ 2: Официальный видео-шот из Yandex Music (по LTE/5G/Wi-Fi)
        if url == nil && !id.isEmpty {
            if let ymURL = await YandexMusicService.shared.getVideoShotUrl(for: id) {
                url = ymURL
            }
        }

        // 3. ПРИОРИТЕТ 3: Локальная студия видео-шотов Aura Studio на ПК (RTX 4060) по Wi-Fi
        if url == nil {
            let key = !id.isEmpty ? id : (track.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video")
            if let studioURL = URL(string: "http://192.168.0.150:5055/videos/\(key).mp4") {
                var headReq = URLRequest(url: studioURL)
                headReq.httpMethod = "HEAD"
                headReq.timeoutInterval = 0.6
                if let (_, resp) = try? await URLSession.shared.data(for: headReq),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    url = studioURL
                }
            }
        }

        guard !Task.isCancelled, player.currentTrack?.id == requestedTrackID else { return }
        videoShotURL = url
        videoShotTrackID = requestedTrackID
        if isVideoShotEnabled, let url {
            setupVideoLooper(url: url)
        }
    }
    private func setupVideoLooper(url: URL) {
        teardownVideoLooper()
        let itemA = AVPlayerItem(url: url)
        itemA.allowedAudioSpatializationFormats = []
        let playerA = AVQueuePlayer(playerItem: itemA)
        playerA.volume = 0
        playerA.isMuted = true
        playerA.actionAtItemEnd = .none
        playerA.preventsDisplaySleepDuringVideoPlayback = false
        videoLooper = AVPlayerLooper(player: playerA, templateItem: itemA)
        videoLooperPlayer = playerA

        playerA.play()
    }
    private func teardownVideoLooper() {
        videoLooper?.disableLooping()
        videoLooperPlayer?.pause()
        videoLooper = nil
        videoLooperPlayer = nil
    }
    private func toggleVideoShot() {
        isVideoShotEnabled.toggle()
        UserDefaults.standard.set(isVideoShotEnabled, forKey: "sonivo_videoshot_enabled")
        if isVideoShotEnabled, videoShotTrackID == track?.id, let videoShotURL {
            setupVideoLooper(url: videoShotURL)
        } else {
            teardownVideoLooper()
            if isVideoShotEnabled { Task { await loadVideoShot() } }
        }
    }
    private func generateAIVideoShot(forceRegenerate: Bool = false) {
        guard let current = track else { return }
        Haptics.tap(.medium)
        waveMessage = forceRegenerate ? "✨ Перегенерация AI Видео-шота под вайб..." : "✨ Запуск создания AI Видео-шота..."
        Task {
            do {
                let lyricsSnippet = lyrics?.lines.prefix(16).map(\.text).joined(separator: "\n")
                let url = try await AIVideoShotGeneratorService.shared.generateVideoShot(
                    for: current,
                    artwork: currentArtworkImage,
                    lyricsSnippet: lyricsSnippet,
                    forceRegenerate: forceRegenerate
                )
                guard player.currentTrack?.id == current.id else { return }
                videoShotURL = url
                videoShotTrackID = current.id
                isVideoShotEnabled = true
                UserDefaults.standard.set(true, forKey: "sonivo_videoshot_enabled")
                setupVideoLooper(url: url)
                waveMessage = "🎬 AI Видео-шот готов!"
                try? await Task.sleep(for: .seconds(3.0))
                if waveMessage == "🎬 AI Видео-шот готов!" { waveMessage = nil }
            } catch {
                waveMessage = "Не удалось создать видео: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(3.5))
                waveMessage = nil
            }
        }
    }

    private func deleteCurrentVideoShot() {
        guard let current = track else { return }
        let cleanId = PlayerCore.yandexTrackID(from: current)
        AIVideoShotGeneratorService.shared.deleteVideoShot(for: cleanId)
        teardownVideoLooper()
        videoShotURL = nil
        videoShotTrackID = nil
        waveMessage = "🗑️ Видео-шот удалён"
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            if waveMessage == "🗑️ Видео-шот удалён" {
                waveMessage = nil
            }
        }
    }
    private func openModal(_ modal: ActivePlayerModal) { Haptics.tap(.light); activeModal = modal }
    private func togglePlayback() { Haptics.tap(.medium); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.togglePlay() }
    private func previousTrack() {
        guard !isCoverSwitching else { return }
        isCoverSwitching = true
        Haptics.tap(.light)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.previous()
        releaseCoverSwitchLock()
    }
    private func nextTrack() {
        guard !isCoverSwitching else { return }
        isCoverSwitching = true
        Haptics.tap(.light)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.next()
        releaseCoverSwitchLock()
    }
    private func releaseCoverSwitchLock() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            isCoverSwitching = false
        }
    }
    private func close() { Haptics.tap(.light); isPresented = false }
    private func openArtist() {
        guard let track else { return }; resolvingArtist = true
        Task { let result = await YandexMusicService.shared.resolvePlayerArtists(for: track); resolvingArtist = false; artistChoices = result; if result.count == 1 { selectedArtist = result[0] } else if !result.isEmpty { activeModal = .artistSelection } }
    }
    private func startTrackWave() {
        guard !waveLoading, let current = track,
              YandexMusicService.ymId(fromFileName: current.fileName) != nil else { return }
        let requestID = UUID()
        trackWaveRequestID = requestID
        let playbackID = PlayerCore.shared.playbackRequestID
        waveLoading = true
        waveMessage = nil
        trackWaveTask?.cancel()
        trackWaveTask = Task { @MainActor in
            defer {
                if trackWaveRequestID == requestID { waveLoading = false }
            }
            let tracks = await YandexMusicService.shared.buildTrackWave(from: current, target: 45)
            guard !Task.isCancelled, trackWaveRequestID == requestID,
                  PlayerCore.shared.playbackRequestID == playbackID, track?.id == current.id else { return }
            let waveTracks = tracks.filter { $0.id != current.id }
            guard !waveTracks.isEmpty else {
                waveMessage = "Не удалось настроить волну. Попробуй ещё раз; текущая очередь сохранена."
                return
            }
            MoodRadioEngine.shared.activateYandexTrackWave(tracks: waveTracks)
            waveActive = true
            waveMessage = "Волна по треку запущена. Текущая песня продолжает играть."
        }
    }

    private func startAIVibeWave() {
        guard !waveLoading, let current = track else { return }
        waveLoading = true
        waveMessage = "✨ AI подбирает треки по вайбу..."
        Task {
            do {
                let (vibeTracks, _, _) = try await AIDJService.shared.generateVibeWave(for: current)
                await MainActor.run {
                    waveLoading = false
                    if vibeTracks.isEmpty {
                        waveMessage = "Не удалось найти похожие по вайбу треки"
                    } else {
                        waveActive = true
                        waveMessage = "✨ AI Вайб-волна: \(vibeTracks.count) треков"
                        MoodRadioEngine.shared.startTrackWave(seed: current, initialTracks: vibeTracks)
                    }
                }
            } catch {
                await MainActor.run {
                    waveLoading = false
                    waveMessage = "Ошибка AI подбора: \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                if waveMessage?.hasPrefix("✨") == true || waveMessage?.hasPrefix("Ошибка") == true || waveMessage?.hasPrefix("Не удалось") == true {
                    waveMessage = nil
                }
            }
        }
    }

    private func showOffsetMessage() {
        let ms = Int(SettingsStore.shared.lyricsOffset * 1000)
        let sign = ms > 0 ? "+" : ""
        waveMessage = "⏱ Калибровка текста: \(sign)\(ms) мс"
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            waveMessage = nil
        }
    }
}

// MARK: - Cover Lyrics Continuous Scroll View (Сплошной текст с плавной автопрокруткой)

struct CoverLyricsScrollView: View {
    let lyrics: Lyrics
    let player: ActivePlayerPresentation
    let side: CGFloat
    @State private var settings = SettingsStore.shared
    @State private var isUserInteracting = false
    @State private var interactionResetTask: Task<Void, Never>? = nil
    @State private var activeIndex: Int? = nil

    private func computeActiveIndex(at time: Double) -> Int? {
        guard lyrics.isSynchronized, !lyrics.lines.isEmpty else { return nil }
        let currentTime = max(0, time - LyricsPlaybackClock.routeLatency(for: player) + settings.lyricsOffset)
        if let first = lyrics.lines.first, currentTime < first.startTime {
            return nil
        }
        for (i, line) in lyrics.lines.enumerated() {
            let nextStart = (i + 1 < lyrics.lines.count) ? lyrics.lines[i + 1].startTime : (line.startTime + 20.0)
            if currentTime >= line.startTime && currentTime < nextStart {
                return i
            }
        }
        return lyrics.lines.count - 1
    }

    var body: some View {
        Group {
            if settings.lyricsDesign == .staggered {
                StaggeredLyricsView(lyrics: lyrics, player: player, fontSize: 28)
                    .frame(maxWidth: side, maxHeight: side)
            } else {
                classicBody
            }
        }
    }

    private var classicBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: 26) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        CoverLyricLineRow(
                            text: line.text,
                            isActive: idx == activeIndex,
                            isSynchronized: lyrics.isSynchronized,
                            onSelect: {
                                Haptics.tap(.medium)
                                interactionResetTask?.cancel()
                                isUserInteracting = false
                                if lyrics.isSynchronized {
                                    player.seek(to: LyricsPlaybackClock.seekTime(lineStart: line.startTime, player: player, offset: settings.lyricsOffset))
                                    if !player.isPlaying {
                                        player.resume()
                                    }
                                }
                                withAnimation(.easeInOut(duration: 0.42)) {
                                    proxy.scrollTo(idx, anchor: .center)
                                }
                            }
                        )
                        .id(idx)
                    }

                    if !lyrics.sourceName.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "music.note")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Источник: \(lyrics.sourceName)")
                                .font(.system(size: 11, weight: .medium, design: .default))
                        }
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 16)
                        .padding(.bottom, 28)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, side * 0.35)
            }
            .frame(maxWidth: side, maxHeight: side)
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        if !isUserInteracting {
                            isUserInteracting = true
                        }
                        interactionResetTask?.cancel()
                        interactionResetTask = Task {
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            if !Task.isCancelled {
                                await MainActor.run {
                                    isUserInteracting = false
                                }
                            }
                        }
                    }
            )
            .compositingGroup()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottomTrailing) {
                if isUserInteracting, let activeIndex {
                    Button {
                        Haptics.tap(.light)
                        interactionResetTask?.cancel()
                        isUserInteracting = false
                        withAnimation(.easeInOut(duration: 0.42)) {
                            proxy.scrollTo(activeIndex, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 11, weight: .bold))
                            Text("К текущей")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.70), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.95))
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onChange(of: player.progress) { _, newProgress in
                let newIndex = computeActiveIndex(at: newProgress)
                if newIndex != activeIndex {
                    activeIndex = newIndex
                    if let newIndex, !isUserInteracting {
                        withAnimation(.easeInOut(duration: 0.42)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
            .onAppear {
                let initial = computeActiveIndex(at: player.progress)
                activeIndex = initial
                if let initial {
                    proxy.scrollTo(initial, anchor: .center)
                }
            }
        }
    }
}

private struct CoverLyricLineRow: View {
    let text: String
    let isActive: Bool
    let isSynchronized: Bool
    let onSelect: () -> Void

    private var textColor: Color {
        if isActive {
            return Color.white
        }
        if isSynchronized {
            return Color.white.opacity(0.35)
        }
        return Color.white.opacity(0.85)
    }

    private var shadowColor: Color {
        isActive ? Color.black.opacity(0.40) : Color.clear
    }

    var body: some View {
        Button(action: onSelect) {
            Text(text)
                .font(.system(size: 28, weight: .heavy, design: .default))
                .foregroundStyle(textColor)
                .shadow(color: shadowColor, radius: 4, y: 1.5)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.80)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(LyricsLineButtonStyle())
        .animation(.easeInOut(duration: 0.32), value: isActive)
    }
}

private struct LyricsLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PlayerTimelineSection<Center: View>: View {
    @Bindable var player: ActivePlayerPresentation
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var pendingSeekProgress: Double?
    @State private var lastFeedbackProgress = 0.0
    private let feedback = UISelectionFeedbackGenerator()
    private let center: Center
    init(player: ActivePlayerPresentation, @ViewBuilder center: () -> Center) {
        self.player = player
        self.center = center()
    }
    private var effectiveProgress: Double {
        if isScrubbing { return scrubProgress }
        if let pending = pendingSeekProgress { return pending }
        return player.progress
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let duration = max(player.duration, 0.01)
                let fraction = min(1, max(0, effectiveProgress / duration))
                let width = geo.size.width * fraction
                let trackHeight: CGFloat = isScrubbing ? 7 : 2.5
                let thumbSize: CGFloat = 15

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(isScrubbing ? 0.20 : 0.14))
                        .frame(height: trackHeight)

                    if let bufferFraction = player.bufferedProgress, bufferFraction > 0.005 {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(isScrubbing ? 0.38 : 0.28))
                            .frame(
                                width: max(trackHeight, geo.size.width * min(1.0, CGFloat(bufferFraction))),
                                height: trackHeight
                            )
                            .animation(.easeInOut(duration: 0.2), value: bufferFraction)
                    }

                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.96))
                        .frame(width: max(0, width), height: trackHeight)

                    if isScrubbing {
                        Circle()
                            .fill(.white)
                            .frame(width: thumbSize, height: thumbSize)
                            .offset(x: max(0, min(width - thumbSize / 2, geo.size.width - thumbSize)))
                            .shadow(color: .black.opacity(0.26), radius: 3, y: 1)
                    }
                }
                .animation(.smooth(duration: 0.18), value: isScrubbing)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isScrubbing {
                                isScrubbing = true
                                feedback.prepare()
                            }
                            let f = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                            scrubProgress = f * duration
                            if abs(f - lastFeedbackProgress) > 0.04 {
                                Haptics.scrubTick(feedback)
                                lastFeedbackProgress = f
                            }
                        }
                        .onEnded { value in
                            let f = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                            let target = f * duration
                            pendingSeekProgress = target
                            player.seek(to: target)
                            withAnimation(.smooth(duration: 0.18)) {
                                isScrubbing = false
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                if pendingSeekProgress == target {
                                    pendingSeekProgress = nil
                                }
                            }
                        }
                )
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Позиция воспроизведения")
            .accessibilityValue(
                "\(player.formatted(effectiveProgress)) из \(player.formatted(player.duration))"
            )
            .accessibilityAdjustableAction { direction in
                let step = max(5, player.duration * 0.02)
                switch direction {
                case .increment:
                    player.seek(to: min(effectiveProgress + step, player.duration))
                case .decrement:
                    player.seek(to: max(effectiveProgress - step, 0))
                @unknown default:
                    break
                }
            }

            HStack {
                Text(player.formatted(effectiveProgress))
                    .font(SN.text(.caption2, .medium).monospacedDigit())
                    .foregroundStyle(SN.inkMuted)
                Spacer()
                center
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - effectiveProgress)))
                    .font(SN.text(.caption2, .medium).monospacedDigit())
                    .foregroundStyle(SN.inkMuted)
            }
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            isScrubbing = false
            pendingSeekProgress = nil
        }
        .onChange(of: player.progress) { _, newProgress in
            if let pending = pendingSeekProgress, abs(newProgress - pending) < 1.0 {
                pendingSeekProgress = nil
            }
        }
    }
}
@MainActor
@Observable
final class SystemVolumeManager {
    static let shared = SystemVolumeManager()
    private(set) var volume: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored private weak var systemSlider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingVolume: Float?
    @ObservationIgnored private var requestGeneration = 0

    private init() {
        let session = AVAudioSession.sharedInstance()
        observation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] _, _ in
            // Read the latest hardware value on the main actor, not an older queued KVO value.
            // Never suppress hardware-button updates during a slider gesture.
            Task { @MainActor [weak self] in
                self?.refreshFromSystem()
            }
        }
        for name in [AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification,
                     UIApplication.didBecomeActiveNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Do not replay a request intended for the previous output route.
                    self.pendingVolume = nil
                    self.requestGeneration += 1
                    self.refreshFromSystem()
                }
            })
        }
    }

    func refreshFromSystem() {
        volume = max(0, min(1, AVAudioSession.sharedInstance().outputVolume))
    }

    func attach(slider: UISlider) {
        guard slider.window != nil else { return }
        guard systemSlider !== slider else { return }
        systemSlider = slider
        if let pendingVolume {
            self.pendingVolume = nil
            setVolume(pendingVolume)
        } else {
            refreshFromSystem()
        }
    }

    func detach(slider: UISlider) {
        guard systemSlider === slider else { return }
        systemSlider = nil
        pendingVolume = nil
        requestGeneration += 1
        refreshFromSystem()
    }

    func setVolume(_ newVolume: Float) {
        guard newVolume.isFinite else { return }
        let clamped = max(0, min(1, newVolume))
        requestGeneration += 1
        let generation = requestGeneration
        guard let slider = systemSlider, slider.window != nil else {
            // MPVolumeView can mount after SwiftUI has already delivered an adjustment.
            pendingVolume = clamped
            return
        }
        pendingVolume = nil
        // MPVolumeView controls iOS output volume. PlayerCore.volume is an independent
        // internal transition/sleep-timer gain and must not also attenuate this request.
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: .valueChanged)
        volume = clamped
        // Reconcile even if the route rejects an adjustment or delivers no KVO event.
        // This is a read-back, not a window that ignores hardware updates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.requestGeneration == generation else { return }
            self.refreshFromSystem()
        }
    }
}

final class SystemVolumeHostView: UIView {
    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 60, height: 20))
    private weak var attachedSlider: UISlider?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        clipsToBounds = true
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.isUserInteractionEnabled = false
        addSubview(volumeView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        volumeView.frame = bounds
        findSlider()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            detachVolumeSlider()
            return
        }
        findSlider()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.findSlider()
        }
    }

    func detachVolumeSlider() {
        if let attachedSlider {
            SystemVolumeManager.shared.detach(slider: attachedSlider)
        }
        attachedSlider = nil
    }

    private func findSlider() {
        guard window != nil, let slider = volumeSlider(in: volumeView) else { return }
        if let previous = attachedSlider, previous !== slider {
            SystemVolumeManager.shared.detach(slider: previous)
        }
        attachedSlider = slider
        SystemVolumeManager.shared.attach(slider: slider)
    }

    private func volumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let slider = volumeSlider(in: child) { return slider }
        }
        return nil
    }
}

struct InvisibleVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> SystemVolumeHostView {
        SystemVolumeHostView(frame: CGRect(x: 0, y: 0, width: 60, height: 20))
    }

    func updateUIView(_ uiView: SystemVolumeHostView, context: Context) {}

    static func dismantleUIView(_ uiView: SystemVolumeHostView, coordinator: ()) {
        uiView.detachVolumeSlider()
    }
}

struct FluidVolumeSlider: View {
    @State private var volumeManager = SystemVolumeManager.shared
    @State private var isDragging = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SN.inkMuted)
                .frame(width: 16, height: 16, alignment: .center)

            GeometryReader { geo in
                let width = geo.size.width
                let currentVol = volumeManager.volume
                let progress = CGFloat(max(0.0, min(1.0, currentVol)))
                let filledWidth = width * progress
                let trackHeight: CGFloat = isDragging ? 7 : 2.5
                let thumbSize: CGFloat = isDragging ? 15 : 6

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isDragging ? 0.20 : 0.14))
                        .frame(height: trackHeight)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.94))
                        .frame(width: max(0, filledWidth), height: trackHeight)

                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(
                            color: .black.opacity(isDragging ? 0.26 : 0.16),
                            radius: isDragging ? 3 : 1,
                            y: 1
                        )
                        .offset(x: max(0, min(filledWidth - thumbSize / 2, width - thumbSize)))
                }
                .animation(.smooth(duration: 0.18), value: isDragging)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                Haptics.tap(.light)
                            }
                            let fraction = Float(max(0.0, min(1.0, value.location.x / max(width, 1))))
                            volumeManager.setVolume(fraction)
                        }
                        .onEnded { value in
                            let fraction = Float(max(0.0, min(1.0, value.location.x / max(width, 1))))
                            volumeManager.setVolume(fraction)
                            withAnimation(.smooth(duration: 0.18)) {
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: 36)
            .background(InvisibleVolumeView().frame(width: 60, height: 20).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true))

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SN.inkMuted)
                .frame(width: 16, height: 16, alignment: .center)
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .onAppear { volumeManager.refreshFromSystem() }
        .accessibilityLabel("Громкость")
        .accessibilityValue("\(Int(volumeManager.volume * 100))%")
        .accessibilityAdjustableAction { direction in
            let step: Float = 0.05
            switch direction {
            case .increment:
                volumeManager.setVolume(volumeManager.volume + step)
            case .decrement:
                volumeManager.setVolume(volumeManager.volume - step)
            @unknown default:
                break
            }
        }
    }
}

struct VideoShotPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.videoGravity = videoGravity
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.videoGravity = videoGravity
        uiView.player = player
    }

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) {
        uiView.player = nil
    }

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
        var videoGravity: AVLayerVideoGravity = .resizeAspectFill {
            didSet { playerLayer?.videoGravity = videoGravity }
        }
        var player: AVPlayer? {
            get { playerLayer?.player }
            set {
                playerLayer?.player = newValue
                playerLayer?.videoGravity = videoGravity
            }
        }
    }
}

struct PlayerQualityModalView: View {
    @Bindable var player: ActivePlayerPresentation
    let onDismiss: () -> Void
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            if showingSettings {
                qualitySettingsList
            } else {
                appleMusicQualityCard
            }
        }
    }

    private var appleMusicQualityCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 58, height: 58)
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 16)

            Text(currentQualityTitle)
                .font(.system(size: 24, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Text(currentQualityDescription)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let formatDetail = currentQualityFormatDetail {
                    Text(formatDetail)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                }

                if isTrueDolbyAtmos || (player.isDolbyAtmosActive && player.spatialAudioEnabled) {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                        Text(player.isDolbyAtmosActive ? "Dolby Atmos • пространственный выход" : "Источник Dolby Atmos")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(SN.amber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(SN.amber.opacity(0.12))
                    .clipShape(Capsule())
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showingSettings = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Настройки качества звука")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    onDismiss()
                } label: {
                    Text("OK")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .padding(.top, 8)
        .presentationDetents([.height(410), .medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var isTrueDolbyAtmos: Bool {
        let codec = player.currentCodec?.lowercased() ?? ""
        return codec.contains("atmos")
    }

    private var qualitySettingsList: some View {
        List {
            Section {
                Toggle("Системное пространственное аудио", isOn: $player.spatialAudioEnabled)
            } header: {
                Text("Пространственное аудио")
            } footer: {
                Text("Воспроизводит многоканальное аудио и пространственный стерео-звук для наушников AirPods и совместимой акустики.")
            }

            Section {
                ForEach(AudioQuality.allCases) { quality in
                    Button {
                        player.selectQuality(quality)
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingSettings = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(quality.label)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(quality.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            Spacer()
                            if player.audioQuality == quality {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.white)
                                    .fontWeight(.bold)
                            }
                        }
                    }
                }
            } header: {
                Text("Предпочитаемое качество звука")
            }
        }
        .navigationTitle("Качество звука")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showingSettings = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Назад")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") {
                    onDismiss()
                }
            }
        }
    }

    private var currentQualityTitle: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("atmos") {
            return "Dolby Atmos"
        }
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
            return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"
        }
        if bitrate >= 320 { return "Высокое качество (HQ)" }
        if bitrate > 0 { return "Стандартное качество" }
        return player.audioQuality.badgeText
    }

    private var currentQualityDescription: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("atmos") {
            return "Аудио с объёмным пространственным звучанием Dolby Atmos воспроизводит трёхмерную звуковую сцену с эффектом полного присутствия."
        }
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
            return "Аудио без потерь (Lossless) воспроизводится с оригинальным студийным качеством записи без потери деталей звука."
        }
        if bitrate >= 320 || codec.contains("mp3") || codec.contains("aac") {
            return "Аудио высокого качества (HQ 320 кбит/с) обеспечивает кристальную чистоту звучания с оптимизированным битрейтом."
        }
        return "Качество звука настраивается автоматически или в соответствии с вашими предпочтениями."
    }

    private var currentQualityFormatDetail: String? {
        let codec = player.currentCodec?.uppercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("FLAC") || codec.contains("ALAC") || codec.contains("WAV") {
            let brText = bitrate > 0 ? "\(bitrate) кбит/с" : "до 1411 кбит/с"
            return "Формат: \(codec) • \(brText) • 16/24 бит, 44,1 кГц"
        }
        if !codec.isEmpty {
            let brText = bitrate > 0 ? "\(bitrate) кбит/с" : "320 кбит/с"
            return "Формат: \(codec) • \(brText)"
        }
        return nil
    }
}

// MARK: - Full-spectrum, physically damped player background
struct PlayerMusicReactiveBackdrop: View {
    let artwork: UIImage?
    let palette: [Color]
    let kick: CGFloat
    let bass: CGFloat
    let mids: CGFloat
    let highs: CGFloat
    let level: CGFloat
    let isPlaying: Bool
    let reduceMotion: Bool

    private var interval: TimeInterval {
        1 / Double(max(UIScreen.main.maximumFramesPerSecond, 60))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval,
                                paused: !isPlaying || reduceMotion)) { timeline in
            GeometryReader { geo in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let midDrift = 0.55 + Double(mids) * 0.85
                let x = CGFloat(sin(time * 0.21) * 15.0 * midDrift)
                let y = CGFloat(cos(time * 0.17) * 12.0 * midDrift)
                let tilt = sin(time * 0.10) * (0.35 + Double(mids) * 0.55)
                let impact = max(kick, bass * 0.72)
                let primary = palette.first ?? SN.amber
                let secondary = palette.dropFirst().first ?? SN.ember
                let flashCenter = UnitPoint(
                    x: 0.50 + CGFloat(sin(time * 0.16)) * 0.12,
                    y: 0.54 + CGFloat(cos(time * 0.13)) * 0.10
                )

                ZStack {
                    if let artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 36 + level * 8 - impact * 3)
                            .scaleEffect(1.13 + bass * 0.060 + level * 0.018 + impact * 0.035)
                            .offset(x: x, y: y)
                            .rotationEffect(.degrees(tilt))
                            .saturation(1.12 + Double(mids) * 0.20)
                            .contrast(1.04 + Double(highs) * 0.06 + Double(impact) * 0.08)
                            .brightness(Double(impact) * 0.075)
                            .opacity(0.84 + Double(level) * 0.10)
                            .clipped()
                    } else {
                        LinearGradient(
                            colors: [
                                (palette.first ?? SN.amber).opacity(0.66),
                                (palette.dropFirst().first ?? SN.ember).opacity(0.38),
                                .black
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }

                    PlayerAmbientCoverGlow(
                        palette: palette,
                        bass: bass,
                        mids: mids,
                        highs: highs,
                        level: level,
                        time: time
                    )

                    // Full-screen musical impact: a broad light wave, never an artwork outline.
                    RadialGradient(
                        colors: [
                            Color.white.opacity(Double(impact) * 0.12),
                            primary.opacity(Double(impact) * 0.24),
                            secondary.opacity(Double(impact) * 0.10),
                            .clear
                        ],
                        center: flashCenter,
                        startRadius: 8,
                        endRadius: max(geo.size.width, geo.size.height) * (0.58 + impact * 0.16)
                    )
                    .scaleEffect(1 + impact * 0.07)
                    .blendMode(.screen)

                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.14), location: 0.0),
                            .init(color: .clear, location: 0.22),
                            .init(color: .clear, location: 0.63),
                            .init(color: .black.opacity(0.34), location: 0.84),
                            .init(color: .black.opacity(0.68), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// Bass controls mass, mids control flow, and highs control short clean glints.
struct PlayerAmbientCoverGlow: View {
    let palette: [Color]
    let bass: CGFloat
    let mids: CGFloat
    let highs: CGFloat
    let level: CGFloat
    let time: TimeInterval

    private var c1: Color { palette.first ?? SN.amber }
    private var c2: Color { palette.dropFirst().first ?? SN.ember }
    private var c3: Color { palette.dropFirst(2).first ?? Color.white }

    var body: some View {
        GeometryReader { geo in
            let maxDim = max(geo.size.width, geo.size.height)
            let b = Double(max(0, min(1, bass)))
            let m = Double(max(0, min(1, mids)))
            let h = Double(max(0, min(1, highs)))
            let l = Double(max(0, min(1, level)))
            let bassCenter = UnitPoint(
                x: 0.48 + CGFloat(sin(time * 0.15)) * 0.09,
                y: 0.68 + CGFloat(cos(time * 0.12)) * 0.065
            )
            let midCenter = UnitPoint(
                x: 0.50 + CGFloat(sin(time * 0.23 + 1.2)) * CGFloat(0.16 + m * 0.055),
                y: 0.42 + CGFloat(cos(time * 0.19)) * CGFloat(0.12 + m * 0.040)
            )
            let highCenter = UnitPoint(
                x: 0.70 + CGFloat(sin(time * 0.38)) * 0.15,
                y: 0.28 + CGFloat(cos(time * 0.33)) * 0.11
            )

            ZStack {
                RadialGradient(
                    colors: [
                        c1.exposureAdjust(0.28 + b * 0.24)
                            .headroom(1.20 + b * 0.38)
                            .opacity(0.24 + b * 0.20),
                        c1.opacity(0.09 + l * 0.08),
                        .clear
                    ],
                    center: bassCenter,
                    startRadius: 18,
                    endRadius: maxDim * (0.50 + b * 0.14)
                )

                RadialGradient(
                    colors: [
                        c2.exposureAdjust(0.24 + m * 0.22)
                            .headroom(1.16 + m * 0.30)
                            .opacity(0.20 + m * 0.22),
                        c3.opacity(0.075 + m * 0.085),
                        .clear
                    ],
                    center: midCenter,
                    startRadius: 12,
                    endRadius: maxDim * (0.36 + m * 0.12)
                )
                .blendMode(.screen)

                RadialGradient(
                    colors: [
                        Color.white.exposureAdjust(0.34 + h * 0.26)
                            .headroom(1.22 + h * 0.38)
                            .opacity(0.075 + h * 0.18),
                        c3.opacity(0.055 + h * 0.10),
                        .clear
                    ],
                    center: highCenter,
                    startRadius: 5,
                    endRadius: maxDim * (0.16 + h * 0.075)
                )
                .blendMode(.plusLighter)
            }
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

#Preview("Full player") { PlayerScreenV2(isPresented: .constant(true)) }
#Preview("Timeline") { PlayerTimelineSection(player: ActivePlayerPresentation()) { EmptyView() }.padding() }

// Lightweight, self-contained decoration: no second Metal renderer or audio probe.
// This slow flow communicates an animated control, not a fabricated beat clock.
private struct PlayerTrackWaveBackdrop: View {
    let colors: [Color]
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var startedAt = Date()

    var body: some View {
        let paint = colors.isEmpty ? [Color.primary.opacity(0.18)] : colors
        let shouldAnimate = isVisible && isPlaying && scenePhase == .active && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimate)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt) * 0.32
            Canvas { context, size in
                for index in 0..<3 {
                    let offset = Double(index) * 1.7
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for step in 0...24 {
                        let x = Double(step) / 24
                        let y = 0.64 + sin(x * 5.4 + time + offset) * 0.18
                        path.addLine(to: CGPoint(x: size.width * x, y: size.height * y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [paint[index % paint.count].opacity(0.32), paint[(index + 1) % paint.count].opacity(0.08)]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                }
            }
        }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
