import SwiftUI
import UIKit

// MARK: - Sonivo Native Full Player (iOS 120 FPS, Contrast Protection, Isolated Gestures)

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

    // Player Modes
    @State private var showLyricsMode = false
    @State private var showQueue = false
    @State private var showEqualizer = false
    @State private var showSleepTimer = false
    @State private var showSettings = false

    // Lyrics state
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false

    // Scrubber local state to prevent gesture interference
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    // Wave builder state
    @State private var buildingTrackWave = false
    @State private var trackWaveReady = false
    @State private var trackWaveMessage: String?

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
            let coverSide = min(geo.size.width - 48, 380)

            ZStack {
                // Adaptive Dynamic Blurred Canvas
                background

                // Protective Dark Vignette Gradient (Ensures 100% readability over white/bright covers)
                contrastProtectionVignette

                VStack(spacing: 0) {
                    // Top Bar (Dismiss Grabber + Actions)
                    topBar
                        .padding(.top, max(geo.safeAreaInsets.top, 14))
                        .padding(.horizontal, 20)

                    Spacer(minLength: 8)

                    // Center Stage: Album Artwork OR Live Synced Lyrics (Apple Music Style)
                    if showLyricsMode {
                        lyricsStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)),
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

                    Spacer(minLength: 12)

                    // Lower Controls Deck (Protected with frosted glass contrast)
                    lowerControlsDeck
                        .padding(.horizontal, 22)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: track?.id) { _, _ in
            buildingTrackWave = false
            trackWaveReady = false
            trackWaveMessage = nil
        }
    }

    // MARK: - Background Layer (120 FPS Optimized)

    private var background: some View {
        let colors = palette.isEmpty ? [AG.amber, AG.ember, Color.black] : palette
        let first = colors[0]
        let second = colors[min(1, colors.count - 1)]
        let third = colors[min(2, colors.count - 1)]
        let pulse = reduceMotion ? 0 : beat

        return ZStack {
            Color.black

            // Ambient background artwork blur
            if let track, let image = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 65, opaque: true)
                    .opacity(0.38)
            }

            RadialGradient(colors: [first.opacity(0.70), .clear], center: .topLeading, startRadius: 10, endRadius: 460)
                .scaleEffect(1 + pulse * 0.08, anchor: .topLeading)

            RadialGradient(colors: [second.opacity(0.55), .clear], center: .trailing, startRadius: 20, endRadius: 400)
                .scaleEffect(1 + pulse * 0.12, anchor: .trailing)
                .opacity(0.55 + pulse * 0.25)

            RadialGradient(colors: [third.opacity(0.48), Color.black.opacity(0.85)], center: .bottomLeading, startRadius: 0, endRadius: 520)
                .scaleEffect(1 + pulse * 0.06, anchor: .bottomLeading)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: beat)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .compositingGroup()
    }

    // MARK: - Contrast Protection Vignette (Safeguards against Pure White Covers)

    private var contrastProtectionVignette: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.65), location: 0.0),
                .init(color: Color.black.opacity(0.15), location: 0.20),
                .init(color: Color.black.opacity(0.15), location: 0.55),
                .init(color: Color.black.opacity(0.75), location: 0.82),
                .init(color: Color.black.opacity(0.92), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Top Navigation Bar

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            // Pull-down grabber pill
            VStack(spacing: 4) {
                Capsule()
                    .fill(Color.white.opacity(0.65))
                    .frame(width: 40, height: 5)
            }
            .frame(width: 140, height: 40)
            .contentShape(Rectangle())
            .gesture(closeGesture)

            Spacer()

            Menu {
                Button { withAnimation(AG.spring) { showLyricsMode.toggle() } } label: {
                    Label(showLyricsMode ? "Показать обложку" : "Караоке", systemImage: "quote.bubble")
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
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.8))
            }
        }
    }

    // MARK: - Center Stage: Artwork (With Dedicated Isolated Horizontal Swipe)

    private func artworkStage(side: CGFloat) -> some View {
        let pulse = reduceMotion ? 0 : beat

        return ZStack {
            // Bass Reactive Glow
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(AngularGradient(colors: [AG.amber, AG.ember, .clear, AG.amber], center: .center))
                .frame(width: side + 16, height: side + 16)
                .blur(radius: 18 + pulse * 8)
                .opacity(player.isPlaying ? 0.35 + pulse * 0.25 : 0.15)
                .scaleEffect(0.98 + pulse * 0.05)

            // Album Artwork with Swipe-to-change-tracks
            artwork
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.55), radius: 24, y: 14)
                .scaleEffect(player.isPlaying ? 1.0 : 0.96)
                .offset(x: coverDragX)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { val in
                            // Only respond to horizontal swipes on the cover
                            if abs(val.translation.width) > abs(val.translation.height) {
                                coverDragX = val.translation.width * 0.65
                            }
                        }
                        .onEnded { val in
                            let threshold: CGFloat = 60
                            if val.translation.width < -threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(AG.fastSpring) { coverDragX = -side }
                                nextTrack()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                    coverDragX = 0
                                }
                            } else if val.translation.width > threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(AG.fastSpring) { coverDragX = side }
                                previousTrack()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                    coverDragX = 0
                                }
                            } else {
                                withAnimation(AG.fastSpring) { coverDragX = 0 }
                            }
                        }
                )
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: beat)
        .animation(.smooth(duration: 0.28), value: player.isPlaying)
        .id(track?.id)
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

    // MARK: - Center Stage: Live Synced Lyrics (Apple Music Sing Mode)

    private var lyricsStage: some View {
        LyricsView(lyrics: lyrics, isLoading: lyricsLoading)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }

    // MARK: - Lower Controls Deck (Compact Liquid Glass Capsule & Native Controls)

    private var lowerControlsDeck: some View {
        VStack(spacing: 12) {
            // Track Metadata (Title & Artist) - Floating with crisp contrast
            metadata
                .padding(.horizontal, 4)

            // Compact Frosted Glass Capsule (Scrubber + Transport Controls)
            VStack(spacing: 14) {
                // Scrubber (Isolated Drag Gesture - No Conflict)
                scrubber

                // Main Playback Transport Buttons
                transportControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .background(
                ZStack {
                    // Dark base for 100% white-cover contrast
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.38))

                    // Adaptive artwork tint (subtly matches album color)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill((palette.first ?? AG.ember).opacity(0.14))
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.24),
                                (palette.first ?? .white).opacity(0.12),
                                Color.black.opacity(0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 16, y: 8)

            // Volume & AirPlay Bar
            volumeAndAirPlayBar
                .padding(.horizontal, 6)

            // Bottom Quick Action Dock (Lyrics, Repeat, Shuffle, EQ, Queue)
            bottomDock
        }
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? "Sonivo")
                    .font(AG.display(22, .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Button(action: openArtist) {
                    HStack(spacing: 4) {
                        Text(track?.artist ?? "")
                            .font(AG.text(15, .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                        if resolvingArtist {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil || resolvingArtist)
            }

            Spacer(minLength: 0)

            if let track {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    library.toggleFavorite(track)
                } label: {
                    Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(library.isTrackFavorite(track) ? AG.amber : .white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Scrubber (Isolated Slider)

    private var scrubber: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let maxDuration = max(player.duration, 0.01)
                let currentFraction = min(1.0, max(0.0, effectiveProgress / maxDuration))

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(height: isScrubbing ? 8 : 5)

                    // Track filled
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * currentFraction, height: isScrubbing ? 8 : 5)

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
            .frame(height: 22)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isScrubbing)

            // Timers
            HStack {
                Text(player.formatted(effectiveProgress))
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - effectiveProgress)))
            }
            .font(AG.text(11.5, .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: Transport Controls (Native Standard Style)

    private var transportControls: some View {
        HStack(spacing: 24) {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.92))

            Spacer()

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.90))
                    .frame(width: 72, height: 72)
                    .background(Color.white, in: Circle())
                    .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
            }
            .buttonStyle(GlassPressStyle(scale: 0.90))

            Spacer()

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle(scale: 0.92))
        }
        .padding(.horizontal, 16)
    }

    // MARK: Volume & AirPlay Bar

    private var volumeAndAirPlayBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))

            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { player.volume = Float($0) }
                ),
                in: 0...1
            )
            .tint(Color.white)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))

            AirPlayButtonView()
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 6)
    }

    // MARK: Bottom Quick Action Dock

    private var bottomDock: some View {
        HStack(spacing: 8) {
            // Lyrics Toggle
            Button {
                withAnimation(AG.spring) {
                    showLyricsMode.toggle()
                }
            } label: {
                Image(systemName: showLyricsMode ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(showLyricsMode ? AG.amber : .white.opacity(0.75))
                    .frame(width: 40, height: 40)
                    .background(showLyricsMode ? AG.amber.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Shuffle
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.shuffle ? AG.amber : .white.opacity(0.70))
                    .frame(width: 40, height: 40)
                    .background(player.shuffle ? AG.amber.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Repeat Mode
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.repeatMode != .off ? AG.amber : .white.opacity(0.70))
                    .frame(width: 40, height: 40)
                    .background(player.repeatMode != .off ? AG.amber.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // EQ
            Button {
                showEqualizer = true
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.eqEnabled ? AG.amber : .white.opacity(0.70))
                    .frame(width: 40, height: 40)
                    .background(player.eqEnabled ? AG.amber.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Queue
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(showQueue ? AG.amber : .white.opacity(0.70))
                    .frame(width: 40, height: 40)
                    .background(showQueue ? AG.amber.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Actions

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

