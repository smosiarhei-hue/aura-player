import SwiftUI
import UIKit
import AVKit
import MediaPlayer

// MARK: - Sonivo Native Full Player (Apple Music iOS Standard & Video-Shot Live Canvas)

struct PlayerScreenV2: View {
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared
    @State private var taste = UserTasteEngine.shared
    @State private var analyzer = SpectrumAnalyzer.shared
    @State private var settings = SettingsStore.shared
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // Controls scale with the system font size and never go below 44x44 pt.
    @ScaledMetric(relativeTo: .body) private var controlSide: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var iconGlyph: CGFloat = 20
    @ScaledMetric(relativeTo: .title) private var skipGlyph: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var playGlyph: CGFloat = 46

    @State private var dragY: CGFloat = 0
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var resolvingArtist = false
    @State private var dismissing = false

    // Unified Modal State Machine to eliminate CATransaction sheet conflicts
    enum ActivePlayerModal: String, Identifiable {
        case queue, equalizer, sleepTimer, settings, quality, artistSelection
        var id: String { rawValue }
    }
    @State private var activeModal: ActivePlayerModal? = nil

    // Player Display Modes
    @State private var showLyricsMode = false
    @State private var isVideoShotMode = UserDefaults.standard.bool(forKey: "player.videoshot")
    @State private var dj = AutoMixDJEngine.shared

    // Video Shot state
    @State private var videoShotUrl: URL? = nil
    @State private var videoShotLoading = false

    // Track Wave state
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String? = nil

    // Lyrics state
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false

    // Scrubber local state to prevent gesture interference
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    // Cover swipe gesture offset
    @State private var coverDragX: CGFloat = 0
    @State private var artworkPaletteColors: [Color] = []

    private var track: Track? { player.currentTrack }

    /// Minimum comfortable touch target, grown with Dynamic Type but never shrunk.
    private var tapSide: CGFloat { max(44, min(controlSide, 64)) }

    /// The video canvas only runs while it can actually be seen and playback is
    /// live. On pause, on stop, or once the app leaves the foreground it is torn
    /// down and the standard artwork comes back, so nothing decodes video in the
    /// background and the battery is left alone.
    private var videoShotActive: Bool {
        isVideoShotMode
            && videoShotUrl != nil
            && player.isPlaying
            && scenePhase == .active
    }

    private var palette: [Color] {
        if !artworkPaletteColors.isEmpty { return artworkPaletteColors }
        if let p = track?.palette, !p.isEmpty { return p }
        return Palette.seeded(42).colors
    }
    private var beat: CGFloat {
        let source = max(analyzer.streamLevel, analyzer.bass, analyzer.level)
        return player.isPlaying ? CGFloat(min(max(source, 0), 1)) : 0
    }

    private var effectiveProgress: Double {
        isScrubbing ? scrubProgress : player.progress
    }

    private func updatePalette(from image: UIImage) {
        let hexes = LibraryStore.artworkPalette(from: image)
        let colors = hexes.compactMap { Color(hex: $0) }
        if !colors.isEmpty {
            withAnimation(.easeInOut(duration: 0.35)) {
                artworkPaletteColors = colors
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let coverSide = min(geo.size.width - 64, geo.size.height * 0.39, 360)
            let dismissThreshold = max(geo.size.height * 0.38, 240)
            let dragProgress = min(max(dragY / dismissThreshold, 0), 1)

            ZStack {
                // 1. Dynamic Background: Fullscreen Live VideoShot Canvas OR Fluid HDR Background
                if videoShotActive, let videoShotUrl {
                    VideoShotPlayerView(url: videoShotUrl, isActive: true)
                        .scaleEffect(1.02)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    // Progressive Apple Music Gradient & Frosted Blur Fog over the lower half
                    VStack(spacing: 0) {
                        Spacer()
                        ZStack(alignment: .bottom) {
                            // Real progressive frosted blur material behind the gradient
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .mask(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: .black.opacity(0.35), location: 0.25),
                                            .init(color: .black.opacity(0.85), location: 0.65),
                                            .init(color: .black, location: 1.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color.black.opacity(0.30), location: 0.20),
                                    .init(color: Color.black.opacity(0.70), location: 0.58),
                                    .init(color: Color.black.opacity(0.95), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .frame(height: geo.size.height * 0.60)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                } else {
                    fluidHDRBackground
                    contrastProtectionVignette
                }

                // 2. Main Player Container (Controls ALWAYS pinned on top).
                //    Only the background layers ignore the safe area, so no control
                //    can escape it on devices with a large sensor housing.
                VStack(spacing: 0) {
                    // Top Bar (Grabber Pill) - Smoothly fades out during drag
                    topHeader
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                        .opacity(max(0, 1.0 - Double(dragProgress * 2.2)))

                    Spacer(minLength: 4)

                    // Center Stage: Standard Square Artwork or Synced Lyrics
                    if showLyricsMode {
                        lyricsStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else if !videoShotActive {
                        artworkStage(side: coverSide)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    } else {
                        // Open space in VideoShot mode so background video is clearly visible
                        Spacer(minLength: 20)
                    }

                    Spacer(minLength: 6)

                    // Floating status line: Track Wave toast only.
                    // The AutoMix mark lives in the center slot under the timeline.
                    if let waveMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AG.amber)
                            Text(waveMessage)
                                .font(AG.text(12, .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 4)
                    }

                    // Lower Controls Section (Apple Music Standard Layout) - ALWAYS ON SCREEN
                    appleMusicLowerDeck
                        .padding(.horizontal, 24)
                        .padding(.bottom, 10)
                        .opacity(max(0, 1.0 - Double(dragProgress * 1.7)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { val in
                            guard !isScrubbing else { return }
                            if val.translation.height > 0 {
                                dragY = val.translation.height
                            }
                        }
                        .onEnded { val in
                            guard !isScrubbing else { return }
                            let velocity = val.predictedEndTranslation.height
                            if val.translation.height > 120 || velocity > 280 {
                                close()
                            } else {
                                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                                    dragY = 0
                                }
                            }
                        }
                )
            }
            .offset(y: max(0, dragY))
            .scaleEffect(1.0 - (dragProgress * 0.10), anchor: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: dragY > 0 ? (22 + dragProgress * 20) : 0, style: .continuous))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(dismissing)
        .animation(.easeInOut(duration: 0.28), value: dj.isTransitionActive)
        .animation(.easeInOut(duration: 0.30), value: videoShotActive)
        .sheet(item: $activeModal) { modal in
            NavigationStack {
                switch modal {
                case .queue:
                    QueueSheetView()
                case .equalizer:
                    PlayerEQSheetView()
                case .sleepTimer:
                    SleepTimerSheetView()
                case .settings:
                    SettingsView()
                case .quality:
                    audioQualitySheetContent
                case .artistSelection:
                    artistSelectionSheetContent
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistView(artistId: artist.id) }
                .preferredColorScheme(.dark)
        }
        .task(id: track?.id) {
            await loadLyrics()
            await loadVideoShot()
        }
    }

    // MARK: - Dynamic Fluid HDR Mesh Background (GPU 120 FPS Optimized)

    private var fluidHDRBackground: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: palette.isEmpty ? [AG.amber.opacity(0.85), AG.ember.opacity(0.70), Color.black] : palette.map { $0.opacity(0.80) } + [Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            FluidWaveView(colors: palette, isBackgroundMode: true)
                .scaleEffect(1.40)
            RadialGradient(
                colors: [(palette.first ?? AG.amber).opacity(0.65), Color.clear],
                center: .top,
                startRadius: 40,
                endRadius: 460
            )
        }
        .blur(radius: 45)
        .scaleEffect(1.20)
        .saturation(1.35)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .compositingGroup()
    }

    // MARK: - Contrast Protection Vignette

    private var contrastProtectionVignette: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.45), location: 0.0),
                .init(color: Color.black.opacity(0.10), location: 0.20),
                .init(color: Color.black.opacity(0.18), location: 0.50),
                .init(color: Color.black.opacity(0.68), location: 0.78),
                .init(color: Color.black.opacity(0.92), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Top Header (Grabber & Dismiss)

    private var topHeader: some View {
        HStack(alignment: .center) {
            // Dismiss button
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: max(15, iconGlyph * 0.75), weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            // Center Grabber Pill
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 42, height: 5)
                .frame(width: 120, height: tapSide)
                .contentShape(Rectangle())
                .gesture(closeGesture)

            Spacer()

            // Right spacer for visual balance
            Color.clear
                .frame(width: tapSide, height: tapSide)
        }
        .frame(minHeight: tapSide)
    }

    // MARK: - Center Stage: Standard Artwork (Screenshot 1)

    private func artworkStage(side: CGFloat) -> some View {
        ZStack {
            artwork
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.45), radius: player.isPlaying ? 28 : 14, y: player.isPlaying ? 16 : 8)
                .scaleEffect(player.isPlaying ? 1.0 : 0.88)
                .offset(x: coverDragX)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { val in
                            if abs(val.translation.width) > abs(val.translation.height) {
                                coverDragX = val.translation.width * 0.60
                            }
                        }
                        .onEnded { val in
                            let threshold: CGFloat = 45
                            if val.translation.width < -threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = -side }
                                nextTrack()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { coverDragX = 0 }
                            } else if val.translation.width > threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = side }
                                previousTrack()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { coverDragX = 0 }
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = 0 }
                            }
                        }
                )
        }
        .frame(width: side, height: side)
        .animation(.spring(response: 0.38, dampingFraction: 0.75), value: player.isPlaying)
        .id(track?.id)
    }

    @ViewBuilder private var artwork: some View {
        if videoShotActive, let videoShotUrl {
            VideoShotPlayerView(url: videoShotUrl, isActive: true)
                .transition(.opacity)
        } else if let track, let image = LibraryStore.cachedArtworkImage(for: track) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .onAppear { updatePalette(from: image) }
        } else if let cover = track?.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
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
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    /// Finding a clip never switches the mode on by itself: the video canvas is
    /// opt-in and only the toggle (or the last remembered choice) enables it.
    private func loadVideoShot() async {
        videoShotUrl = nil
        guard let track else { return }
        let ymId = YandexMusicService.ymId(fromFileName: track.fileName) ?? (track.isStream ? track.streamUrlString : nil) ?? ""
        guard !ymId.isEmpty else { return }

        videoShotLoading = true
        let url = await YandexMusicService.shared.getVideoShotUrl(for: ymId)
        if player.currentTrack?.id == track.id {
            withAnimation(.easeInOut(duration: 0.30)) {
                videoShotUrl = url
            }
        }
        videoShotLoading = false
    }

    // MARK: - Center Stage: Live Synced Lyrics

    private var lyricsStage: some View {
        LyricsView(lyrics: lyrics, isLoading: lyricsLoading)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }

    // MARK: - Apple Music Standard Lower Controls Deck (Screenshot 1 & 2)

    private var appleMusicLowerDeck: some View {
        VStack(spacing: 14) {
            // Compact Video-Shot / Artwork Toggle Pill (only when a clip really exists)
            if videoShotUrl != nil {
                HStack {
                    Spacer()
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                            isVideoShotMode.toggle()
                            UserDefaults.standard.set(isVideoShotMode, forKey: "player.videoshot")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isVideoShotMode ? "video.fill" : "photo.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(isVideoShotMode ? "Видеошот" : "Обложка")
                                .font(AG.text(11, .semibold))
                        }
                        .foregroundStyle(isVideoShotMode ? AG.amber : .white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 0.8))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(GlassPressStyle())
                }
                .padding(.bottom, -6)
            }

            // Track Metadata (Title, Artist, Like, Track Wave, 3-Dots)
            metadataRow

            // Scrubber Slider & Lossless Badge
            scrubberSection

            // Large Native Transport Controls (Backward, Play/Pause, Forward)
            transportControls

            // System Volume Slider
            volumeBar

            // Apple Music Bottom Bar (Lyrics, AirPlay, Queue)
            appleMusicBottomBar
        }
    }

    // MARK: Metadata Row (Left: Title & Artist, Right: Like + Track Wave + 3-Dots)

    private var metadataRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? "Sonivo")
                    .font(AG.display(22, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Button(action: openArtist) {
                    HStack(spacing: 4) {
                        Text(track?.artist ?? "")
                            .font(AG.text(17, .semibold))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if resolvingArtist {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil || resolvingArtist)
            }

            Spacer(minLength: 8)

            // Right Action Icons: Like (Heart) + Track Wave + 3-Dots Menu
            HStack(spacing: 6) {
                if let track {
                    // Like Button (Heart: Adds to Library & Favorites)
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        library.toggleFavorite(track)
                        taste.recordLike(track: track)
                    } label: {
                        Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                            .font(.system(size: max(19, iconGlyph), weight: .semibold))
                            .foregroundStyle(library.isTrackFavorite(track) ? Color.pink : .white.opacity(0.80))
                            .frame(width: tapSide, height: tapSide)
                            .contentShape(Circle())
                    }
                    .buttonStyle(GlassPressStyle())
                    .accessibilityLabel(library.isTrackFavorite(track) ? "Убрать из избранного" : "В избранное")

                    // "Моя волна по треку" (Track Wave / Infinite Flow related to song)
                    Button(action: startTrackWave) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: max(18, iconGlyph * 0.95), weight: .semibold))
                            .foregroundStyle(waveActive ? AG.amber : .white.opacity(0.80))
                            .frame(width: tapSide, height: tapSide)
                            .contentShape(Circle())
                    }
                    .buttonStyle(GlassPressStyle())
                    .accessibilityLabel("Моя волна по треку")
                }

                Menu {
                    Section("Воспроизведение") {
                        Button(action: startTrackWave) {
                            Label("Моя волна по треку", systemImage: "dot.radiowaves.left.and.right")
                        }
                        if videoShotUrl != nil {
                            Button {
                                withAnimation(AG.spring) {
                                    isVideoShotMode.toggle()
                                    UserDefaults.standard.set(isVideoShotMode, forKey: "player.videoshot")
                                }
                            } label: {
                                Label(isVideoShotMode ? "Стандартная обложка" : "Видео-шоты / Live Canvas", systemImage: isVideoShotMode ? "photo" : "play.rectangle.fill")
                            }
                        }
                        Button {
                            withAnimation(AG.spring) { showLyricsMode.toggle() }
                        } label: {
                            Label(showLyricsMode ? "Скрыть текст песни" : "Текст песни", systemImage: "quote.bubble")
                        }
                    }

                    Section("Звук и очередь") {
                        Button { openModal(.queue) } label: {
                            Label("Очередь воспроизведения", systemImage: "list.bullet")
                        }
                        Button { openModal(.equalizer) } label: {
                            Label("Эквалайзер", systemImage: "slider.vertical.3")
                        }
                        Button { openModal(.sleepTimer) } label: {
                            Label("Таймер сна", systemImage: "timer")
                        }
                    }

                    Section("Приложение") {
                        Button { openModal(.settings) } label: {
                            Label("Настройки", systemImage: "gearshape")
                        }
                        Button {
                            Task {
                                let ok = await SonivoDiagnostics.shared.sendReportToTelegram()
                                if ok {
                                    waveMessage = "✅ Диагностика отправлена в Telegram"
                                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                                    if waveMessage?.contains("Диагностика") == true { waveMessage = nil }
                                }
                            }
                        } label: {
                            Label("Отправить логи в Telegram", systemImage: "paperplane")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            player.stopAndClear()
                            close()
                        } label: {
                            Label("Остановить и очистить", systemImage: "stop.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: max(19, iconGlyph), weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: tapSide, height: tapSide)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Ещё")
            }
        }
    }

    // MARK: Scrubber Section with Audio Quality Badge (Screenshot 1 & 2)

    private var scrubberSection: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let maxDuration = max(player.duration, 0.01)
                let currentFraction = min(1.0, max(0.0, effectiveProgress / maxDuration))
                let barHeight: CGFloat = isScrubbing ? 11 : 7
                let knob: CGFloat = isScrubbing ? 19 : 0

                ZStack(alignment: .leading) {
                    // Track background line
                    Capsule()
                        .fill(Color.white.opacity(0.24))
                        .frame(height: barHeight)

                    // Filled progress line
                    Capsule()
                        .fill(Color.white.opacity(isScrubbing ? 1.0 : 0.85))
                        .frame(width: max(barHeight, geo.size.width * currentFraction), height: barHeight)

                    // Thumb knob (grows out of the bar while scrubbing)
                    if isScrubbing {
                        Circle()
                            .fill(Color.white)
                            .frame(width: knob, height: knob)
                            .shadow(color: Color.black.opacity(0.45), radius: 5)
                            .offset(x: max(0, min(geo.size.width * currentFraction - knob / 2, geo.size.width - knob)))
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            if !isScrubbing {
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) {
                                    isScrubbing = true
                                }
                            }
                            let fraction = min(1.0, max(0.0, val.location.x / geo.size.width))
                            scrubProgress = fraction * maxDuration
                        }
                        .onEnded { val in
                            let fraction = min(1.0, max(0.0, val.location.x / geo.size.width))
                            let target = fraction * maxDuration
                            player.seek(to: target)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                                isScrubbing = false
                            }
                        }
                )
            }
            .frame(height: 44)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isScrubbing)

            // Timings and center status line (AutoMix mark while mixing, otherwise quality badge)
            HStack(alignment: .center) {
                Text(player.formatted(effectiveProgress))
                    .font(AG.text(12, .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(isScrubbing ? 0.95 : 0.55))

                Spacer()

                centerStatusLabel

                Spacer()

                Text("-" + player.formatted(max(0, player.duration - effectiveProgress)))
                    .font(AG.text(12, .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(isScrubbing ? 0.95 : 0.55))
            }
        }
    }

    /// Apple Music places a single caption in the center slot under the timeline.
    /// While AutoMix is blending two tracks it shows the shimmering AutoMix mark,
    /// the rest of the time the interactive audio quality badge.
    @ViewBuilder private var centerStatusLabel: some View {
        if dj.isTransitionActive {
            AutoMixBadge()
                .transition(.opacity)
        } else {
            qualityBadgeButton
                .transition(.opacity)
        }
    }

    private var qualityBadgeButton: some View {
        Button {
            openModal(.quality)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .bold))
                Text(qualityBadgeLabel)
                    .font(AG.text(11, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8)))
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .accessibilityLabel("Качество звука: \(qualityBadgeLabel)")
    }

    private var qualityBadgeLabel: String {
        if let codec = player.currentCodec?.lowercased(), codec.contains("flac") {
            return "Hi-Res Lossless"
        }
        if (player.currentBitrate ?? 0) >= 320 {
            return "Lossless"
        }
        return player.audioQuality.badgeText
    }

    // MARK: Transport Controls (Large Apple Music Symbols)

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: max(30, min(skipGlyph, 44)), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: max(52, tapSide))
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.90))
            .accessibilityLabel("Предыдущий трек")

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: max(40, min(playGlyph, 58)), weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: max(60, tapSide))
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.88))
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: max(30, min(skipGlyph, 44)), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: max(52, tapSide))
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.90))
            .accessibilityLabel("Следующий трек")
        }
        .padding(.vertical, 8)
    }

    // MARK: Volume Slider (Apple Music Native System MPVolumeView)

    private var volumeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.50))

            NativeVolumeSlider()
                .frame(height: 32)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.50))
        }
        .padding(.horizontal, 4)
    }

    // MARK: Apple Music Bottom Bar (Lyrics, AirPlay, Queue)

    private var appleMusicBottomBar: some View {
        HStack(alignment: .center) {
            // Left: Lyrics / Sing
            Button {
                withAnimation(AG.spring) {
                    showLyricsMode.toggle()
                }
            } label: {
                Image(systemName: showLyricsMode ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: max(19, iconGlyph), weight: .semibold))
                    .foregroundStyle(showLyricsMode ? AG.amber : .white.opacity(0.65))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Текст песни")

            Spacer()

            // Center: AirPlay route picker (Standard native size)
            AirPlayButtonView()
                .frame(width: tapSide, height: tapSide)
                .contentShape(Rectangle())
                .accessibilityLabel("AirPlay")

            Spacer()

            // Right: Queue sheet
            Button {
                openModal(.queue)
            } label: {
                Image(systemName: activeModal == .queue ? "list.bullet.rectangle.portrait.fill" : "list.bullet")
                    .font(.system(size: max(19, iconGlyph), weight: .semibold))
                    .foregroundStyle(activeModal == .queue ? AG.amber : .white.opacity(0.65))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Очередь")
        }
        .padding(.horizontal, 28)
        .frame(minHeight: tapSide)
    }

    // MARK: - Active Modal Views

    private var audioQualitySheetContent: some View {
        List {
            Section {
                ForEach(AudioQuality.allCases) { q in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        player.selectQuality(q)
                        activeModal = nil
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(q.label)
                                    .font(AG.text(15, .semibold))
                                    .foregroundStyle(.white)
                                Text(q.detail)
                                    .font(AG.text(12, .regular))
                                    .foregroundStyle(.white.opacity(0.60))
                            }
                            Spacer()
                            if player.audioQuality == q {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(AG.amber)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("Качество звука и кодеки")
            } footer: {
                Text("Для треков из Яндекс Музыки стриминг во FLAC Lossless активируется автоматически при стабильном интернет-соединении.")
            }
        }
        .navigationTitle("Качество звука")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { activeModal = nil }
                    .foregroundStyle(AG.amber)
            }
        }
    }

    private var artistSelectionSheetContent: some View {
        List {
            Section("Выберите исполнителя") {
                ForEach(artistChoices) { artist in
                    Button {
                        activeModal = nil
                        selectedArtist = artist
                    } label: {
                        HStack {
                            Text(artist.name)
                                .font(AG.text(16, .medium))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.40))
                        }
                        .padding(.vertical, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .navigationTitle("Исполнители")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Закрыть") { activeModal = nil }
                    .foregroundStyle(AG.amber)
            }
        }
    }

    private func openModal(_ modal: ActivePlayerModal) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            activeModal = modal
        }
    }

    // MARK: - Actions

    private func startTrackWave() {
        guard let current = track else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        waveLoading = true
        Task {
            let waveTracks = await YandexMusicService.shared.buildTrackWave(from: current, target: 45)
            waveLoading = false
            if !waveTracks.isEmpty {
                player.queue = waveTracks
                waveActive = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(AG.spring) {
                    waveMessage = "🌊 Моя волна по треку запущена"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { waveMessage = nil }
                }
            }
        }
    }

    private func loadLyrics() async {
        lyrics = nil
        guard let requestedTrack = track else {
            lyricsLoading = false
            return
        }

        lyricsLoading = true
        let result = try? await LyricsService.shared.fetchLyrics(for: requestedTrack)
        guard player.currentTrack?.id == requestedTrack.id else { return }
        lyrics = result
        lyricsLoading = false
    }

    private func togglePlayback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.togglePlay()
    }

    private func previousTrack() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.previous()
    }

    private func nextTrack() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                openModal(.artistSelection)
            }
        }
    }

    private func close() {
        guard !dismissing else { return }
        dismissing = true
        isPresented = false
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragY = value.translation.height
            }
            .onEnded { value in
                let velocity = value.predictedEndTranslation.height
                if value.translation.height > 120 || velocity > 280 {
                    close()
                } else {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                        dragY = 0
                    }
                }
            }
    }
}

// MARK: - AutoMix mark (Apple Music "Mixing" style)
//
// Plain system text, no frame, no stroke, no material or solid backdrop of any kind.
// A soft glow sits under the glyphs and a white HDR highlight sweeps across the
// letters from left to right, driven by TimelineView instead of repeatForever.
// With Reduce Motion the mark stays static and only keeps the glow.

struct AutoMixBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let title = "AutoMix"
    private let sweepCycle: TimeInterval = 2.6

    var body: some View {
        Group {
            if reduceMotion {
                mark(sweep: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let phase = time.truncatingRemainder(dividingBy: sweepCycle) / sweepCycle
                    mark(sweep: CGFloat(phase))
                }
            }
        }
        .accessibilityLabel(Text(title))
        .allowsHitTesting(false)
    }

    private func mark(sweep: CGFloat?) -> some View {
        let label = Text(title)
            .font(.system(size: 12, weight: .semibold, design: .default))

        return label
            .foregroundStyle(.white.opacity(0.78))
            .overlay {
                if let sweep {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let band = max(width * 0.5, 22)
                        let travel = width + band * 2

                        LinearGradient(
                            colors: [.clear, .white.opacity(0.35), .white, .white.opacity(0.35), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: -band + sweep * travel)
                        .frame(width: width, height: geo.size.height, alignment: .leading)
                        .clipped()
                        .blendMode(.plusLighter)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
            .shadow(color: .white.opacity(0.45), radius: 5)
            .shadow(color: .white.opacity(0.18), radius: 11)
            .fixedSize()
            .compositingGroup()
    }
}

// MARK: - VideoShot Player View (Native Looping Canvas - Pure AVPlayerLayer, No PiP)

struct VideoShotPlayerView: UIViewRepresentable {
    let url: URL
    var isActive: Bool = true

    func makeUIView(context: Context) -> VideoShotUIView {
        let view = VideoShotUIView()
        view.configure(with: url)
        view.setActive(isActive)
        return view
    }

    func updateUIView(_ uiView: VideoShotUIView, context: Context) {
        uiView.configure(with: url)
        uiView.setActive(isActive)
    }

    static func dismantleUIView(_ uiView: VideoShotUIView, coordinator: Coordinator) {
        uiView.teardown()
    }
}

final class VideoShotUIView: UIView {
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var currentURL: URL?
    private var wantsPlayback = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        clipsToBounds = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    /// Video decoding is expensive, so the loop is stopped the moment the canvas
    /// leaves the screen instead of quietly running behind the artwork.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            queuePlayer?.pause()
        } else if wantsPlayback {
            queuePlayer?.play()
        }
    }

    func configure(with url: URL) {
        guard currentURL != url else { return }
        currentURL = url

        queuePlayer?.pause()
        queuePlayer = nil
        looper = nil
        playerLayer?.removeFromSuperlayer()

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false

        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.addSublayer(layer)
        self.playerLayer = layer

        if wantsPlayback {
            player.play()
        }
    }

    func setActive(_ active: Bool) {
        wantsPlayback = active
        guard let queuePlayer else { return }
        if active {
            if queuePlayer.rate == 0 { queuePlayer.play() }
        } else if queuePlayer.rate != 0 {
            queuePlayer.pause()
        }
    }

    func teardown() {
        wantsPlayback = false
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        looper?.disableLooping()
        looper = nil
        queuePlayer = nil
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        currentURL = nil
    }
}

// MARK: - Native iOS System Volume Slider (MPVolumeView)

struct NativeVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.85)
                slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
            }
        }
        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
