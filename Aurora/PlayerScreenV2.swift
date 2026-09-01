import SwiftUI
import UIKit

// MARK: - Sonivo Native Full Player (Apple Music iOS Standard & Video-Shot Live Canvas)

struct PlayerScreenV2: View {
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared
    @State private var taste = UserTasteEngine.shared
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

    // Player Display Modes
    @State private var showLyricsMode = false
    @State private var isVideoShotMode = UserDefaults.standard.bool(forKey: "player.videoshot")
    @State private var showQueue = false
    @State private var showEqualizer = false
    @State private var showSleepTimer = false
    @State private var showSettings = false
    @State private var dj = AutoMixDJEngine.shared

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

    private var track: Track? { player.currentTrack }
    private var palette: [Color] { track?.palette ?? Palette.seeded(42).colors }
    private var beat: CGFloat {
        let source = max(analyzer.streamLevel, analyzer.bass, analyzer.level)
        return player.isPlaying ? CGFloat(min(max(source, 0), 1)) : 0
    }

    private var effectiveProgress: Double {
        isScrubbing ? scrubProgress : player.progress
    }

    var body: some View {
        GeometryReader { geo in
            let coverSide = min(geo.size.width - 64, geo.size.height * 0.39, 360)

            ZStack {
                // 1. Dynamic Fluid HDR Mesh Background (drifting & color-adaptive)
                fluidHDRBackground

                // 2. Protective Vignette Gradient for 100% Text & Control Readability
                contrastProtectionVignette

                // 3. Main Player Container
                VStack(spacing: 0) {
                    // Top Bar (Grabber Pill & Video-Shot Toggle)
                    topHeader
                        .padding(.top, max(geo.safeAreaInsets.top, 12))
                        .padding(.horizontal, 24)

                    Spacer(minLength: 4)

                    // Center Stage: Standard Square Artwork, Video-Shot Live Canvas, OR Synced Lyrics
                    if showLyricsMode {
                        lyricsStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)),
                                removal: .opacity.combined(with: .scale(scale: 0.95))
                            ))
                    } else if isVideoShotMode {
                        videoShotStage(geo: geo)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 1.05)),
                                removal: .opacity.combined(with: .scale(scale: 0.95))
                            ))
                    } else {
                        artworkStage(side: coverSide)
                            .frame(maxWidth: .infinity)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)),
                                removal: .opacity.combined(with: .scale(scale: 0.95))
                            ))
                    }

                    Spacer(minLength: 6)

                    // Floating toast for Track Wave or AutoMix DJ Transition
                    if dj.isTransitionActive {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AG.amber)
                            Text("AutoMix DJ: \(dj.activeStyle.localizedTitle)")
                                .font(AG.text(12, .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().stroke(AG.amber.opacity(0.45), lineWidth: 1)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 4)
                    } else if let waveMessage {
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

                    // Lower Controls Section (Apple Music Standard Layout)
                    appleMusicLowerDeck
                        .padding(.horizontal, 24)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { val in
                            guard !isScrubbing else { return }
                            if val.translation.height > 0 && abs(val.translation.height) > abs(val.translation.width) * 1.15 {
                                dragY = val.translation.height * 0.80
                            }
                        }
                        .onEnded { val in
                            guard !isScrubbing else { return }
                            if val.translation.height > 75 || val.predictedEndTranslation.height > 150 {
                                close()
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    dragY = 0
                                }
                            }
                        }
                )
            }
            .offset(y: max(0, dragY))
            .scaleEffect(1 - min(max(dragY, 0) / 1800, 0.035), anchor: .bottom)
            .opacity(1 - min(max(dragY, 0) / 650, 0.25))
        }
        .ignoresSafeArea()
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
            await loadLyrics()
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

    // MARK: - Top Header (Grabber & Video Shot Toggle)

    private var topHeader: some View {
        HStack(alignment: .center) {
            // Dismiss button
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle())

            Spacer()

            // Center Grabber Pill
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 42, height: 5)
                .frame(width: 120, height: 36)
                .contentShape(Rectangle())
                .gesture(closeGesture)

            Spacer()

            // Video-Shot Live Canvas Toggle
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) {
                    isVideoShotMode.toggle()
                    UserDefaults.standard.set(isVideoShotMode, forKey: "player.videoshot")
                }
            } label: {
                Image(systemName: isVideoShotMode ? "rectangle.inset.filled.and.person.filled" : "play.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isVideoShotMode ? AG.amber : .white.opacity(0.70))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle())
        }
        .frame(height: 38)
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

    // MARK: - Center Stage: Video-Shot Live Canvas (Screenshot 2)

    private func videoShotStage(geo: GeometryProxy) -> some View {
        ZStack(alignment: .bottom) {
            // Fullscreen Live Artwork / Video Canvas
            artwork
                .frame(width: geo.size.width, height: geo.size.height * 0.65)
                .clipped()
                .scaleEffect(1.08)

            // Middle-to-Bottom Progressive Blur & Gradient Mask (dissolves behind text and controls)
            VStack(spacing: 0) {
                Spacer()

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Color.black.opacity(0.35), location: 0.35),
                        .init(color: Color.black.opacity(0.85), location: 0.75),
                        .init(color: Color.black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.40)
            }
        }
        .allowsHitTesting(false)
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
                .foregroundStyle(.white.opacity(0.85))
        }
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
                        if resolvingArtist {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil || resolvingArtist)
            }

            Spacer(minLength: 8)

            // Right Action Icons: Dislike + Like (Heart) + Track Wave + 3-Dots Menu
            HStack(spacing: 8) {
                if let track {
                    // Like Button (Heart: Adds to Library & Favorites)
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        library.toggleFavorite(track)
                        taste.recordLike(track: track)
                    } label: {
                        Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(library.isTrackFavorite(track) ? Color.pink : .white.opacity(0.80))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .buttonStyle(GlassPressStyle())

                    // "Моя волна по треку" (Track Wave / Infinite Flow related to song)
                    Button(action: startTrackWave) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(waveActive ? AG.amber : .white.opacity(0.80))
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(waveActive ? AG.amber.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(GlassPressStyle())
                }

                Menu {
                    Button(action: startTrackWave) {
                        Label("Моя волна по треку", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        withAnimation(AG.spring) { showLyricsMode.toggle() }
                    } label: {
                        Label(showLyricsMode ? "Показать обложку" : "Караоке / Текст песни", systemImage: "quote.bubble")
                    }
                    Button {
                        withAnimation(AG.spring) { isVideoShotMode.toggle() }
                    } label: {
                        Label(isVideoShotMode ? "Стандартная обложка" : "Видео-шоты / Live Canvas", systemImage: "play.rectangle")
                    }
                    Button { showQueue = true } label: {
                        Label("Очередь воспроизведения", systemImage: "list.bullet")
                    }
                    Button { showEqualizer = true } label: {
                        Label("Эквалайзер", systemImage: "slider.vertical.3")
                    }
                    Button { showSleepTimer = true } label: {
                        Label("Таймер сна", systemImage: "timer")
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
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
            }
        }
    }

    // MARK: Scrubber Section with Audio Quality Badge (Screenshot 1 & 2)

    private var scrubberSection: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let maxDuration = max(player.duration, 0.01)
                let currentFraction = min(1.0, max(0.0, effectiveProgress / maxDuration))

                ZStack(alignment: .leading) {
                    // Track background line
                    Capsule()
                        .fill(Color.white.opacity(0.24))
                        .frame(height: isScrubbing ? 6 : 4)

                    // Filled progress line
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: geo.size.width * currentFraction, height: isScrubbing ? 6 : 4)

                    // Thumb knob (visible when scrubbing)
                    if isScrubbing {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: Color.black.opacity(0.4), radius: 4)
                            .offset(x: max(0, min(geo.size.width * currentFraction - 8, geo.size.width - 16)))
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isScrubbing = true
                            let fraction = min(1.0, max(0.0, val.location.x / geo.size.width))
                            scrubProgress = fraction * maxDuration
                        }
                        .onEnded { val in
                            let fraction = min(1.0, max(0.0, val.location.x / geo.size.width))
                            let target = fraction * maxDuration
                            player.seek(to: target)
                            isScrubbing = false
                        }
                )
            }
            .frame(height: 18)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isScrubbing)

            // Timings and Center Quality Badge (Lossless / Dolby Atmos)
            HStack(alignment: .center) {
                Text(player.formatted(effectiveProgress))
                    .font(AG.text(12, .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))

                Spacer()

                // Apple Music Quality Badge
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .bold))
                    Text((player.currentBitrate ?? 0) >= 320 ? "Hi-Res Lossless" : "Lossless")
                        .font(AG.text(11, .semibold))
                }
                .foregroundStyle(.white.opacity(0.70))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.10)))

                Spacer()

                Text("-" + player.formatted(max(0, player.duration - effectiveProgress)))
                    .font(AG.text(12, .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    // MARK: Transport Controls (Large Apple Music Symbols)

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.90))

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.88))

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.90))
        }
        .padding(.vertical, 8)
    }

    // MARK: Volume Slider (Apple Music Standard)

    private var volumeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.50))

            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ),
                in: 0...1
            )
            .tint(Color.white.opacity(0.85))

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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(showLyricsMode ? AG.amber : .white.opacity(0.65))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle())

            Spacer()

            // Center: AirPlay route picker (Standard native size)
            AirPlayButtonView()
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())

            Spacer()

            // Right: Queue sheet
            Button {
                showQueue = true
            } label: {
                Image(systemName: showQueue ? "list.bullet.rectangle.portrait.fill" : "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(showQueue ? AG.amber : .white.opacity(0.65))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle())
        }
        .padding(.horizontal, 28)
        .frame(height: 44)
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
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragY = min(value.translation.height * 0.75, 180)
            }
            .onEnded { value in
                if value.translation.height > 65 || value.predictedEndTranslation.height > 120 {
                    close()
                } else {
                    withAnimation(AG.fastSpring) {
                        dragY = 0
                    }
                }
            }
    }
}

