import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation
import AVKit
import Combine

struct PlayerScreenV2: View {
    @State private var player = ActivePlayerPresentation()
    @State private var analysis = AutoMixV2AnalysisRuntime.shared
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
    @State private var lyricsVoiceOver = UIAccessibility.isVoiceOverRunning
    @State private var lyricsControlsHideTask: Task<Void, Never>?
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @Namespace private var nowPlayingCoverSpace
    @State private var coverDragX: CGFloat = 0
    @State private var isCoverSwitching = false
    @State private var coverSwitchTask: Task<Void, Never>?
    @State private var coverSettleTask: Task<Void, Never>?
    @State private var coverVisualSide = 0
    @State private var coverSwitchGeneration = UUID()
    @State private var coverTransitionOutgoing: Track?
    @State private var coverTransitionIncoming: Track?
    @State private var coverTransitionOther: Track?
    @State private var coverTransitionOutgoingImage: UIImage?
    @State private var coverTransitionDirection = 0
    @State private var dominantArtworkColor: Color?
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String?
    @State private var trackWaveTask: Task<Void, Never>?
    @State private var trackWaveRequestID = UUID()
    @State private var videoShotURL: URL?
    @AppStorage("sonivo_videoshot_enabled") private var isVideoShotEnabled = true
    @State private var videoPlayback = VideoShotPlaybackController()
    @Environment(\.colorScheme) private var preferredScheme
    private var videoLooperPlayer: AVQueuePlayer? { videoPlayback.player }
    @State private var videoShotTrackID: UUID?
    @ObservedObject private var aiVideoShotService = AIVideoShotGeneratorService.shared
    @State private var artworkPaletteColors: [Color] = []
    @State private var resolvedArtworkPaletteTrackID: UUID?
    @State private var paletteTrackId: UUID?
    @State private var artworkTrackId: UUID?
    @State private var currentArtworkImage: UIImage?
    @State private var cachedPhrases: [LyricPhrase] = []
    @State private var spectrum = SpectrumAnalyzer.shared
    /// Menu dismissal races `.sheet` presentation; defer and cancel so EQ/queue/settings
    /// do not open then bounce closed, and stale taps cannot land after the player closes.
    @State private var pendingModalTask: Task<Void, Never>?
    private let tapSide: CGFloat = SN.tapTarget

    private var kickEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicKick, gain: 1.32)
    }

    private var bassEnergy: CGFloat {
        guard player.isPlaying, !reduceMotion else { return 0 }
        return boostedVisualEnergy(spectrum.dynamicBass, gain: 1.18)
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
        GeometryReader { safeGeometry in
            let safeTop = safeGeometry.safeAreaInsets.top
            let safeBottom = safeGeometry.safeAreaInsets.bottom
            GeometryReader { geo in
                let totalHeight = geo.size.height
                let totalWidth = geo.size.width
                let topInset = max(safeTop, 12)
                // Cover clears the Island with room — soft alpha dissolve meets the atmosphere.
                let coverTopClearance: CGFloat = max(28, topInset + 12)
                // Apple Music: edge-to-edge square. Height == width — never taller.
                // A taller stage would enlarge the layout without adding image detail.
                // Wave banner + secondary glass row left the player; keep room for
                // lyrics · AirPlay · queue · sleep · EQ and a slight downward nudge.
                let reservedFirstScreenControls: CGFloat = 248 + max(safeBottom, 8)
                let standardArtworkStageHeight = min(
                    totalWidth,
                    totalHeight - reservedFirstScreenControls - coverTopClearance
                )

                ZStack(alignment: .top) {
                    // Native UIBlur of the cover — soft top dissolve + lyrics backdrop
                    // (WWDC26: blur the art so it sits behind the transcript).
                    NowPlayingAtmosphere(
                        primary: coverWashPrimary,
                        secondary: coverWashSecondary,
                        secondaryAmount: coverWashAmount
                    )
                    .frame(width: totalWidth, height: totalHeight)
                    .opacity(isFullScreenVideoShot ? 0 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    // Palette bloom only in Island clearance + control deck — never mid-cover.
                    coverAccentWash
                        .frame(width: totalWidth, height: totalHeight)
                        .opacity(isFullScreenVideoShot ? 0 : (showLyricsMode ? 0.40 : 1))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    background
                        .frame(width: totalWidth, height: totalHeight)
                        .opacity(isFullScreenVideoShot ? 1 : (showLyricsMode ? 0.28 : 0.06))
                        .clipped()

                    // Attach the native rendering layer during preparation too. Readiness
                    // only controls visibility; loop-item status must not recreate the layer.
                    if let videoLooperPlayer {
                        VideoShotPlayerView(player: videoLooperPlayer, videoGravity: .resizeAspectFill)
                            .frame(width: totalWidth, height: totalHeight).clipped()
                            .overlay(Color.black.opacity(0.32))
                            .opacity(isFullScreenVideoShot ? 1 : 0)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }

                    if showLyricsMode {
                        lyricsPlayerLayout(
                            width: totalWidth,
                            height: totalHeight,
                            topInset: topInset,
                            safeAreaBottom: safeBottom
                        )
                        .transition(LyricsPresentationMotion.transition(reduceMotion: reduceMotion))
                        .zIndex(2)
                    } else {
                        // Cover sits below the Island; colorful wash lives BEHIND the art only.
                        ZStack(alignment: .top) {
                            ScrollView(.vertical) {
                                VStack(spacing: 0) {
                                    Color.clear
                                        .frame(height: coverTopClearance)
                                        .accessibilityHidden(true)
                                    artworkStage(width: totalWidth, height: standardArtworkStageHeight)
                                        .frame(width: totalWidth, height: standardArtworkStageHeight)
                                    // Nudge the control panel slightly below the cover dissolve.
                                    Spacer(minLength: 14)
                                    lowerDeck(safeAreaBottom: safeBottom, coverWidth: totalWidth)
                                }
                                // Fill the first screen so Spacer can drop the control panel down.
                                .frame(maxWidth: .infinity, minHeight: totalHeight)
                            }
                            .scrollIndicators(.hidden)
                            .accessibilityLabel("Плеер и дополнительные действия")

                            topHeader
                                .padding(.top, topInset)
                                .padding(.horizontal, 20)
                        }
                        .transition(LyricsPresentationMotion.transition(reduceMotion: reduceMotion))
                    }

                }
                .frame(width: totalWidth, height: totalHeight, alignment: .top)
                .animation(LyricsPresentationMotion.animation(reduceMotion: reduceMotion), value: showLyricsMode)
                // Apple Music Now Playing is always dark over the blurred cover wash.
                .environment(\.colorScheme, (isFullScreenVideoShot || !showLyricsMode) ? .dark : preferredScheme)
            }
            .ignoresSafeArea(.container, edges: .all)
        }
        .background(SN.bg.ignoresSafeArea())
        .sheet(item: $activeModal) { modal in
            // One presentation owner per modal: never wrap views that already own a
            // NavigationStack / presentationDetents (EQ, Settings, Quality) — nested
            // stacks make sheets flash, snap detent, or leave chrome non-interactive.
            switch modal {
            case .queue:
                NavigationStack { QueueSheetView() }
            case .equalizer:
                PlayerEQSheetView()
            case .sleepTimer:
                NavigationStack { SleepTimerSheetView() }
            case .settings:
                SettingsView()
            case .quality:
                PlayerQualityModalView(player: player, onDismiss: { activeModal = nil })
            case .artistSelection:
                NavigationStack { artistSelectionSheet }
            case .lyrics:
                NavigationStack {
                    LyricsView(lyrics: lyrics, isLoading: lyricsLoading, player: player)
                        .navigationTitle("Текст песни").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
                }
            }
        }
        .sheet(item: $selectedArtist) { artist in
            NavigationStack {
                ArtistView(artistId: artist.id)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled(false)
        }
        .task { await player.observeTimeline() }
        .task(id: track?.id) {
            async let p: () = refreshPalette()
            async let l: () = loadLyrics()
            _ = await (p, l)
        }
        .task(id: videoLoadKey) { await loadVideoShot() }
        .onChange(of: player.isPlaying) { _, playing in
            updateVideoPlayback()
            if showLyricsMode {
                if !playing { lyricsControlsVisible = true }
                scheduleLyricsControlsHide()
            }
        }
        .onChange(of: player.isBuffering) { _, buffering in
            if showLyricsMode {
                if buffering { lyricsControlsVisible = true }
                scheduleLyricsControlsHide()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            lyricsVoiceOver = UIAccessibility.isVoiceOverRunning
            if showLyricsMode { revealLyricsControls() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelCoverSwitch() }
            updateVideoPlayback()
            lyricsControlsHideTask?.cancel()
            if phase == .active, showLyricsMode { revealLyricsControls() }
        }
        .onChange(of: isPresented) { _, _ in updateVideoPlayback() }
        .onChange(of: isVideoShotEnabled) { _, enabled in
            if !enabled { teardownVideoLooper() }
        }
        .onChange(of: track?.id) { _, _ in
            if let incoming = coverTransitionIncoming {
                if player.currentTrack?.id != incoming.id { cancelCoverSwitch() }
            } else if (isCoverSwitching && coverSwitchTask != nil) || abs(coverDragX) > 0.5 {
                cancelCoverSwitch()
            }
            trackWaveTask?.cancel()
            trackWaveRequestID = UUID()
            waveLoading = false
            waveMessage = nil
            lyrics = nil
            cachedPhrases = []
            lyricsLoading = true
        }
        .onChange(of: showLyricsMode) { _, isEnabled in
            updateVideoPlayback()
            lyricsControlsHideTask?.cancel()
            lyricsControlsVisible = isEnabled
            if isEnabled { scheduleLyricsControlsHide() }
            cancelCoverSwitch()
            if !isEnabled {
                // Leaving lyrics must not bounce-dismiss EQ/queue/settings opened from ⋯.
                pendingModalTask?.cancel()
                if activeModal == .lyrics { activeModal = nil }
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
                if isVideoShotEnabled && !reduceMotion {
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
            lyricsControlsHideTask?.cancel()
            coverSwitchTask?.cancel()
            coverSettleTask?.cancel()
            coverVisualSide = 0
            pendingModalTask?.cancel()
            pendingModalTask = nil
            coverSwitchGeneration = UUID()
            isCoverSwitching = false
            coverTransitionOutgoing = nil
            coverTransitionIncoming = nil
            coverTransitionOther = nil
            coverTransitionOutgoingImage = nil
            coverDragX = 0
            trackWaveRequestID = UUID()
            waveLoading = false
            teardownVideoLooper()
        }
    }

    private var isFullScreenVideoShot: Bool {
        isVideoShotEnabled && videoPlayback.isReady && videoShotTrackID == track?.id && videoLooperPlayer != nil && !showLyricsMode && !reduceMotion
    }

    private var background: some View {
        // A spatially uniform cover tint over semantic light/dark background.
        // Never display a previous track's extracted palette while the new cover is loading.
        let coverColor = resolvedArtworkPaletteTrackID == track?.id ? dominantArtworkColor : nil
        let base = showLyricsMode ? Color.black : SN.bg
        return AnyView(base.overlay((coverColor ?? Color.clear).opacity(0.22))
            .ignoresSafeArea()
            .allowsHitTesting(false))
    }

    private var topHeader: some View {
        HStack {
            Button {
                Haptics.tap(.light)
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(SN.ink.opacity(0.88))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            Capsule()
                .fill(SN.ink.opacity(0.40))
                .frame(width: 40, height: 5)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .contentShape(Rectangle())
        .simultaneousGesture(headerCloseGesture)
    }

    private var headerCloseGesture: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            guard PlayerDismissPolicy.shouldClose(x: Double(value.translation.width),
                y: Double(value.translation.height), predictedY: Double(value.predictedEndTranslation.height)) else { return }
            close()
        }
    }

    private func lyricsPlayerLayout(
        width: CGFloat,
        height: CGFloat,
        topInset: CGFloat,
        safeAreaBottom: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            lyricsTopHeader
                .simultaneousGesture(headerCloseGesture)
                .padding(.top, topInset)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())

            compactLyricsMetadata
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 6)

            inlineLyricsStage(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    revealLyricsControls()
                }
                .simultaneousGesture(DragGesture(minimumDistance: 5)
                    .onChanged { _ in lyricsControlsHideTask?.cancel() }
                    .onEnded { _ in scheduleLyricsControlsHide() })

            if lyricsControlsVisible {
                lyricsControlsDeck(safeAreaBottom: safeAreaBottom, coverWidth: width)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 16) {
                    Button(action: revealLyricsControls) {
                        Label("Показать управление", systemImage: "chevron.up")
                            .font(.subheadline.weight(.medium)).foregroundStyle(SN.accent)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .accessibilityHint("Показать перемотку, паузу и переключение треков")
                    closeLyricsButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, max(safeAreaBottom, 12))
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .animation(LyricsPresentationMotion.controlsAnimation(reduceMotion: reduceMotion), value: lyricsControlsVisible)
        .environment(\.colorScheme, .dark)
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
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }

    private var compactLyricsMetadata: some View {
        let current = track
        return HStack(spacing: 16) {
            artwork
                .frame(width: 56, height: 56)
                .matchedGeometryEffect(
                    id: LyricsPresentationMotion.coverMorphID,
                    in: nowPlayingCoverSpace,
                    properties: .frame,
                    isSource: showLyricsMode
                )
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

    private func lyricsControlsDeck(safeAreaBottom: CGFloat, coverWidth: CGFloat) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text(lyricsVoiceOver ? "Управление плеером" : (player.isBuffering ? "Ожидание воспроизведения" : (player.isPlaying ? "Скроется через 10 с без касаний" : "На паузе управление остаётся открытым")))
                    .font(.caption).foregroundStyle(.white.opacity(0.60))
                Spacer(minLength: 8)
                Button("Скрыть") {
                    lyricsControlsHideTask?.cancel()
                    lyricsControlsVisible = false
                }
                .font(.caption.weight(.semibold)).tint(SN.accent)
                .frame(minHeight: 44)
            }
            PlayerTimelineSection(player: player) { centerStatusLabel }
            transportControls(coverWidth: coverWidth)
            HStack(spacing: 16) {
                closeLyricsButton
                Spacer(minLength: 0)
                AirPlayButtonView()
                    .frame(width: tapSide, height: tapSide).glassCircle()
                GlassIconButton(systemImage: "list.bullet", tint: SN.inkMuted, accessibilityLabel: "Очередь") {
                    openModal(.queue)
                }
            }
        }
        // Keep-alive only — never steal taps from transport / queue / Menu (minDistance 0 did).
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { _ in lyricsControlsHideTask?.cancel() }
            .onEnded { _ in scheduleLyricsControlsHide() })
        .padding(.horizontal, 24)
        .padding(.top, 8)
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
        let progress = CoverFoldSwipeMath.progress(dragX: coverDragX, width: width)
        let playScale = player.isPlaying ? 1.0 : 0.97
        let folding = !reduceMotion && coverMixAmount == 0 && !isFullScreenVideoShot
        // Keep artwork nearly edge-to-edge in every mode; the padded shader
        // canvas overflows the stage without shrinking the underlying cover.
        let coverSide = min(width, height)
        let neighbors = coverSwipeNeighbors

        return ZStack {
            if isFullScreenVideoShot {
                // Preserve the artwork footprint and swipe surface while revealing the video.
                Color.clear
                    .frame(width: width, height: height)
            } else if folding {
                ForEach([-1, 0, 1], id: \.self) { slot in
                    if CoverFoldSwipeMath.isVisible(slot: slot, progress: progress) {
                        let slotTrack: Track? = {
                            switch slot {
                            case -1: return neighbors.prev
                            case 1: return neighbors.next
                            default: return coverTransitionOutgoing ?? track
                            }
                        }()
                        // Only reveal the active neighbor during a swipe. At rest the
                        // full-width cover has no stray side plates.
                        if slot == 0 || slot == coverVisualSide {
                            foldedCoverPlate(
                                for: slotTrack,
                                side: coverSide,
                                width: width,
                                slot: slot,
                                progress: progress,
                                morphSource: slot == 0 && abs(progress) < 0.04 && !showLyricsMode
                            )
                            .zIndex(CoverFoldSwipeMath.zIndex(slot: slot, progress: progress))
                        }
                    }
                }
            } else {
                artwork
                    .frame(width: coverSide, height: coverSide)
                    .clipped()
                    .mask(coverDissolveMask)
                    .mask(coverSideDissolveMask)
                    .matchedGeometryEffect(
                        id: LyricsPresentationMotion.coverMorphID,
                        in: nowPlayingCoverSpace,
                        properties: .frame,
                        isSource: !showLyricsMode
                    )
                    .padding(.horizontal, coverSide * 0.10)
                    .padding(.vertical, coverSide * 0.24)
                    .offset(x: coverDragX)
            }
        }
        .frame(width: width, height: height, alignment: .center)
        .scaleEffect(playScale)
        .contentShape(Rectangle())
        .simultaneousGesture(
            showLyricsMode ? nil : DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard !isCoverSwitching, PlayerInteractionPolicy.horizontalIntent(
                        x: Double(value.translation.width), y: Double(value.translation.height)) else { return }
                    coverSettleTask?.cancel()
                    coverVisualSide = value.translation.width < 0 ? 1 : -1
                    let limit = width * CoverFoldSwipeMath.clusterFactor * CoverFoldSwipeMath.progressLimit
                    coverDragX = reduceMotion ? 0 : max(-limit, min(limit, value.translation.width))
                }
                .onEnded { value in
                    guard !isCoverSwitching else { return }
                    if let direction = PlayerInteractionPolicy.trackDirection(
                        x: Double(value.translation.width), y: Double(value.translation.height), width: Double(width)) {
                        // Unknown preview must not block next() (radio refill/shuffle)
                        // or previous() (restart at the beginning of the queue).
                        animateTrackSwipe(direction: direction, width: width)
                    } else {
                        settleCoverDrag()
                    }
                }
        )
        .background {
            CoverSwipeProMotionGate(active: abs(coverDragX) > 0.5 || isCoverSwitching)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.38, dampingFraction: 0.75), value: player.isPlaying)
        .animation(LyricsPresentationMotion.animation(reduceMotion: reduceMotion), value: showLyricsMode)
    }

    /// Only preview a destination that the playback engine can guarantee.
    private var coverSwipeNeighbors: (prev: Track?, next: Track?) {
        if let incoming = coverTransitionIncoming, coverTransitionOutgoing != nil {
            return coverTransitionDirection > 0 ? (coverTransitionOther, incoming) : (incoming, coverTransitionOther)
        }
        guard !player.isTransitionActive, player.currentTrack?.id == track?.id else { return (nil, nil) }
        return player.coverSwipePreviewTracks
    }

    @ViewBuilder
    private func foldedCoverPlate(
        for slotTrack: Track?,
        side: CGFloat,
        width: CGFloat,
        slot: Int,
        progress: CGFloat,
        morphSource: Bool
    ) -> some View {
        let preferred = slotTrack.flatMap { artworkImage(for: $0) }
            ?? (slot == 0 && artworkTrackId == slotTrack?.id ? currentArtworkImage : nil)
        coverLayer(for: slotTrack, preferredImage: preferred)
            .frame(width: side, height: side)
            .matchedGeometryEffect(
                id: LyricsPresentationMotion.coverMorphID,
                in: nowPlayingCoverSpace,
                properties: .frame,
                isSource: morphSource
            )
            // The modifier pads before warping so the visible edge can bend
            // outside the original rectangle, as in the folding-card reference.
            .modifier(CoverFoldAnimatedEffect(side: side, width: width, slot: slot, progress: progress))
            .allowsHitTesting(false)
            .accessibilityHidden(slot != 0)
    }

    /// The fold itself, not only its offset, follows every interpolated frame.
    private struct CoverFoldAnimatedEffect: AnimatableModifier {
        let side: CGFloat
        let width: CGFloat
        let slot: Int
        var progress: CGFloat

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let warp = CoverFoldSwipeMath.warpAmount(slot: slot, progress: progress)
            let magnitude = CGFloat(abs(warp))
            let padX = side * 0.10
            let padY = side * 0.24
            let reveal = Double(min(1, magnitude * 3))
            // Vary the spectral highlight with swipe position, rather than
            // keeping an expensive display-linked animation running at rest.
            let rawHue = 0.65 + Double(progress) * 0.80 + Double(slot) * 0.13
            let hue = rawHue - floor(rawHue)
            let secondHue = (hue + 0.19).truncatingRemainder(dividingBy: 1)
            let thirdHue = (hue + 0.38).truncatingRemainder(dividingBy: 1)
            let streak = CGFloat(0.50 + 0.22 * sin(Double(progress) * .pi * 2 + Double(slot)))
            let shimmer = LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: Color(hue: hue, saturation: 0.72, brightness: 1).opacity(0.70), location: streak - 0.20),
                .init(color: Color(hue: secondHue, saturation: 0.62, brightness: 1).opacity(0.90), location: streak - 0.09),
                .init(color: Color.white.opacity(0.68), location: streak),
                .init(color: Color(hue: thirdHue, saturation: 0.70, brightness: 1).opacity(0.75), location: streak + 0.09),
                .init(color: .clear, location: streak + 0.20),
                .init(color: .clear, location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            let edgeGlow = LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.15), location: 0.25),
                .init(color: .white.opacity(0.75), location: 0.55),
                .init(color: .white, location: 0.80),
                .init(color: .white, location: 1)
            ], startPoint: warp < 0 ? .trailing : .leading,
               endPoint: warp < 0 ? .leading : .trailing)
            // The resting cover blends into the native blur. As a plate bends,
            // smoothly reveal its top/bottom edges so the fold is actually visible.
            func ink(_ rest: Double) -> Color { .black.opacity(rest + (1 - rest) * reveal) }
            let feather = LinearGradient(stops: [
                .init(color: ink(0), location: 0),
                .init(color: ink(0.12), location: 0.025),
                .init(color: ink(0.48), location: 0.065),
                .init(color: ink(0.82), location: 0.11),
                .init(color: ink(1), location: 0.18),
                .init(color: ink(1), location: 0.55),
                .init(color: ink(0.78), location: 0.72),
                .init(color: ink(0.28), location: 0.88),
                .init(color: ink(0), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            let sideFeather = LinearGradient(stops: [
                .init(color: ink(0.42), location: 0),
                .init(color: ink(1), location: 0.045),
                .init(color: ink(1), location: 0.955),
                .init(color: ink(0.42), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            return content
                .overlay {
                    if magnitude > 0.001 {
                        shimmer
                            .mask(edgeGlow)
                            .clipShape(RoundedRectangle(cornerRadius: side * CoverFoldSwipeMath.cornerRadiusFactor, style: .continuous))
                            .blendMode(.screen)
                            .opacity(Double(min(1, magnitude * 1.5)) * 0.85)
                            .allowsHitTesting(false)
                    }
                }
                .mask(feather)
                .mask(sideFeather)
                .padding(.horizontal, padX)
                .padding(.vertical, padY)
                .compositingGroup()
                .distortionEffect(
                    ShaderLibrary.coverFoldWarp(.float(Float(side)), .float(Float(padX)), .float(Float(padY)), .float(warp)),
                    maxSampleOffset: CGSize(width: max(8, side * 0.11), height: max(8, side * 0.26)),
                    isEnabled: magnitude > 0.001
                )
                .scaleEffect(CoverFoldSwipeMath.scale(slot: slot, progress: progress))
                .rotation3DEffect(
                    .degrees(CoverFoldSwipeMath.foldDegrees(slot: slot, progress: progress)),
                    axis: (x: 0, y: 1, z: 0), anchor: .center,
                    perspective: CoverFoldSwipeMath.perspective
                )
                .offset(x: CoverFoldSwipeMath.slotOffset(slot: slot, progress: progress, width: width))
                .opacity(CoverFoldSwipeMath.opacity(slot: slot, progress: progress))
        }
    }

    /// Soft native dissolve into the UIBlur atmosphere — alpha only, never a tinted
    /// or re-blurred strip painted over the art (that seam reads as "the line").
    /// Mid art stays fully opaque — color bloom never punches through.
    private var coverDissolveMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .black.opacity(0.12), location: 0.025),
                .init(color: .black.opacity(0.48), location: 0.065),
                .init(color: .black.opacity(0.82), location: 0.11),
                .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.55),
                .init(color: .black.opacity(0.78), location: 0.72),
                .init(color: .black.opacity(0.28), location: 0.88),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// A narrow side fade avoids hard edges without obscuring the artwork.
    private var coverSideDissolveMask: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.42), location: 0),
            .init(color: .black, location: 0.045),
            .init(color: .black, location: 0.955),
            .init(color: .black.opacity(0.42), location: 1)
        ], startPoint: .leading, endPoint: .trailing)
    }

    @ViewBuilder
    private func inlineLyricsStage(width: CGFloat, height: CGFloat) -> some View {
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
                TypographyLyricsView(lyrics: lyrics, player: player, showsSource: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var closeLyricsButton: some View {
        Button {
            lyricsControlsHideTask?.cancel()
            withAnimation(LyricsPresentationMotion.animation(reduceMotion: reduceMotion)) { showLyricsMode = false }
        } label: {
            Label("Закрыть текст", systemImage: "quote.bubble")
                .font(.subheadline.weight(.semibold)).foregroundStyle(SN.accent)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Вернуться к обычному плееру, музыка продолжит играть")
    }

    private func revealLyricsControls() {
        lyricsControlsVisible = true
        scheduleLyricsControlsHide()
    }

    private var canAutoHideLyricsControls: Bool {
        LyricsControlsPolicy.shouldAutoHide(isPlaying: player.isPlaying, isBuffering: player.isBuffering,
            visible: lyricsControlsVisible, lyricsVisible: showLyricsMode,
            sceneActive: scenePhase == .active, voiceOver: lyricsVoiceOver)
    }

    private func scheduleLyricsControlsHide() {
        lyricsControlsHideTask?.cancel()
        guard canAutoHideLyricsControls else { return }
        lyricsControlsHideTask = Task {
            do { try await Task.sleep(for: .seconds(LyricsControlsPolicy.idleSeconds)) } catch { return }
            guard !Task.isCancelled, canAutoHideLyricsControls else { return }
            lyricsControlsVisible = false
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
        let targetTime = LyricsPlaybackClock.time(for: player)
        var lineIndex = 0
        for (i, line) in lines.enumerated() { if line.startTime <= targetTime { lineIndex = i } else { break } }
        return (lines[lineIndex].text, lineIndex + 1 < lines.count ? lines[lineIndex + 1].text : nil)
    }

    private var coverMixAmount: Double {
        guard player.isTransitionActive,
              let outgoing = player.currentTrack,
              let incoming = player.incomingTrack ?? player.displayTrack,
              outgoing.id != incoming.id else { return 0 }
        return min(1, max(0, player.transitionProgress))
    }

    private var coverWashPrimary: UIImage? {
        if coverMixAmount > 0, let outgoing = player.currentTrack {
            return artworkImage(for: outgoing)
        }
        return track.flatMap { artworkImage(for: $0) }
    }

    private var coverWashSecondary: UIImage? {
        guard coverMixAmount > 0,
              let incoming = player.incomingTrack ?? player.displayTrack else { return nil }
        return artworkImage(for: incoming)
    }

    private var coverWashAmount: CGFloat { CGFloat(coverMixAmount) }

    @ViewBuilder private var artwork: some View {
        let mixP = coverMixAmount

        // Lab Automix stage: the next cover replaces this one by opacity only.
        // The mirrored wash underneath carries the blur.
        if mixP > 0,
           let outgoing = player.currentTrack,
           let incoming = player.incomingTrack ?? player.displayTrack,
           outgoing.id != incoming.id {
            ZStack {
                coverLayer(for: incoming, preferredImage: artworkImage(for: incoming))
                    .opacity(mixP)
                coverLayer(for: outgoing, preferredImage: artworkImage(for: outgoing))
                    .opacity(1 - mixP)
            }
            .animation(reduceMotion ? nil : .linear(duration: 0.05), value: mixP)
        } else {
            coverLayer(for: track, preferredImage: {
                let cached = track.flatMap { LibraryStore.memoryCachedArtworkImage(for: $0) }
                return (artworkTrackId == track?.id ? currentArtworkImage : nil) ?? cached
            }())
        }
    }

    private func artworkImage(for track: Track) -> UIImage? {
        if coverTransitionOutgoing?.id == track.id, let coverTransitionOutgoingImage { return coverTransitionOutgoingImage }
        if artworkTrackId == track.id, let currentArtworkImage { return currentArtworkImage }
        return LibraryStore.memoryCachedArtworkImage(for: track)
    }

    @ViewBuilder
    private func coverLayer(for track: Track?, preferredImage: UIImage?) -> some View {
        // Preserve the entire image, including non-square artwork; the native
        // blurred atmosphere fills any space around it.
        Group {
            if let preferredImage {
                Image(uiImage: preferredImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let raw = track?.coverURL, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).scaledToFit()
                    } else {
                        fallbackArtwork
                    }
                }
            } else {
                fallbackArtwork
            }
        }
        .id(track?.id)
    }
    private var fallbackArtwork: some View {
        ZStack { LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.system(size: 70, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
    }

    private func lowerDeck(safeAreaBottom: CGFloat, coverWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Cover dissolve already pins this cluster low on the first screen.
            VStack(spacing: 8) {
                metadataRow(coverWidth: coverWidth)
                PlayerTimelineSection(player: player) { centerStatusLabel }
                transportControls(coverWidth: coverWidth)
                FluidVolumeSlider()
                    .accessibilityElement(children: .contain)
                primaryUtilityRow
            }
            .padding(.horizontal, 28)
            .padding(.top, 0)
            .padding(.bottom, 4)

            if let error = YandexMusicService.shared.waveError {
                Text(error).font(SN.text(.caption)).foregroundStyle(SN.inkMuted)
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let waveMessage {
                Text(waveMessage)
                    .font(SN.text(.caption, .semibold))
                    .foregroundStyle(SN.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Color.clear
                .frame(height: max(safeAreaBottom, 16))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    /// Saturated cover hues for washes behind the art — never painted over the cover.
    private var coverBloomTones: [Color] {
        let live = resolvedArtworkPaletteTrackID == track?.id ? artworkPaletteColors : []
        var tones = live
        if tones.isEmpty { tones = palette }
        while tones.count < 4 {
            tones.append(tones.last ?? dominantArtworkColor ?? SN.amber)
        }
        return Array(tones.prefix(4))
    }

    /// Bright palette bloom BEHIND the cover: Island clearance + control deck only.
    /// Mid band stays clear so the soft top dissolve reveals native UIBlur, not tint.
    private var coverAccentWash: some View {
        let tones = coverBloomTones
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: tones[0].opacity(0.62), location: 0.00),
                    .init(color: tones[1].opacity(0.32), location: 0.035),
                    .init(color: .clear, location: 0.07),
                    .init(color: .clear, location: 0.58),
                    .init(color: tones[1].opacity(0.24), location: 0.70),
                    .init(color: tones[0].opacity(0.42), location: 0.84),
                    .init(color: tones[2].opacity(0.58), location: 0.94),
                    .init(color: tones[3].opacity(0.70), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [
                    tones[2].opacity(0.22),
                    .clear,
                    .clear,
                    .clear,
                    tones[0].opacity(0.30)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
        }
        .blendMode(.plusLighter)
    }

    /// First-screen footer: lyrics · AirPlay · queue · sleep · EQ.
    private var primaryUtilityRow: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(LyricsPresentationMotion.animation(reduceMotion: reduceMotion)) { showLyricsMode.toggle() }
            } label: {
                Image(systemName: showLyricsMode ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SN.ink.opacity(0.88))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .frame(maxWidth: .infinity)
            .disabled(track == nil)
            .accessibilityLabel("Текст песни")

            AirPlayButtonView()
                .frame(width: tapSide, height: tapSide)
                .frame(maxWidth: .infinity)

            Button { openModal(.queue) } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SN.ink.opacity(0.88))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Очередь")

            sleepTimerUtilityButton
                .frame(maxWidth: .infinity)

            Button { openModal(.equalizer) } label: {
                SonivoEqualizerGlyph()
                    .foregroundStyle(player.eqEnabled ? SN.accent : SN.ink.opacity(0.88))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Эквалайзер")
            .accessibilityValue(player.eqEnabled ? "Включён" : "Выключен")
        }
    }

    private var sleepTimerUtilityButton: some View {
        Button {
            Haptics.tap(.light)
            openModal(.sleepTimer)
        } label: {
            if let timerText = player.sleepTimerFormatted {
                VStack(spacing: 1) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(timerText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(Color.orange)
                .frame(width: tapSide, height: tapSide)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SN.ink.opacity(0.88))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(TactileButtonStyle(scale: 0.92))
        .accessibilityLabel((player.sleepTimerRemaining ?? 0) > 0 ? "Таймер сна активен: \(player.sleepTimerFormatted ?? "")" : "Таймер сна")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: (player.sleepTimerRemaining ?? 0) > 0)
    }

    private var trackWaveMenuAvailability: (catalog: Bool, active: Bool) {
        let catalog = track.flatMap { YandexMusicService.ymId(fromFileName: $0.fileName) } != nil
        let active = YandexMusicService.shared.activeStationId?.hasPrefix("track:") == true
        return (catalog, active)
    }

    private func metadataRow(coverWidth: CGFloat) -> some View {
        let current = track
        return HStack(alignment: .center, spacing: 14) {
            Button(action: openArtist) {
                metadataCarousel(coverWidth: coverWidth)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(current == nil || resolvingArtist || isCoverSwitching || abs(coverDragX) > 2)
            .accessibilityLabel([current?.title ?? "Не играет", current?.artist ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))

            HStack(spacing: 4) {
                Button {
                    guard let current else { return }
                    Haptics.tap(.medium)
                    library.toggleFavorite(current)
                } label: {
                    let favorite = current.map(library.isTrackFavorite) ?? false
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(favorite ? SN.amber : SN.ink.opacity(0.90))
                        .symbolEffect(.bounce, value: favorite)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: tapSide, height: tapSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TactileButtonStyle(scale: 0.90))
                .disabled(current == nil)
                .accessibilityLabel(current.map(library.isTrackFavorite) == true ? "Убрать из избранного" : "В избранное")

                moreMenuButton
            }
        }
    }
    /// Text follows the same gesture as the artwork. Preview labels are decorative;
    /// the artist button and VoiceOver continue to refer only to the playing track.
    private func metadataCarousel(coverWidth: CGFloat) -> some View {
        let progress = CoverFoldSwipeMath.progress(dragX: coverDragX, width: coverWidth)
        let neighbors = coverSwipeNeighbors
        let canPreview = !reduceMotion && coverMixAmount == 0 && !isFullScreenVideoShot
        let activeProgress = canPreview ? progress : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach([-1, 0, 1], id: \.self) { slot in
                    let item = slot == 0 ? (coverTransitionOutgoing ?? track) : (slot < 0 ? neighbors.prev : neighbors.next)
                    let distance = CGFloat(slot) + activeProgress
                    // Keep preview identity alive while a cancelled gesture settles.
                    if slot == 0 || item != nil {
                        metadataText(item, marquee: slot == 0)
                            .frame(width: geo.size.width, alignment: .leading)
                            .rotation3DEffect(
                                .degrees(reduceMotion ? 0 : -Double(distance) * 6),
                                axis: (x: 0, y: 1, z: 0), perspective: 0.6
                            )
                            .offset(x: distance * geo.size.width)
                            .opacity(Double(max(0, 1 - min(1, abs(distance)))))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .frame(height: 54)
    }

    @ViewBuilder
    private func metadataText(_ item: Track?, marquee: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if marquee {
                MarqueeText(text: item?.title ?? "Не играет", font: SN.rounded(.title2, .bold), color: SN.ink, height: 28)
                MarqueeText(text: item?.artist ?? "", font: SN.rounded(.body, .medium), color: SN.ink.opacity(0.72), height: 22)
            } else {
                Text(item?.title ?? "Не играет").font(SN.rounded(.title2, .bold))
                    .foregroundStyle(SN.ink).lineLimit(1).frame(height: 28, alignment: .leading)
                Text(item?.artist ?? "").font(SN.rounded(.body, .medium))
                    .foregroundStyle(SN.ink.opacity(0.72)).lineLimit(1).frame(height: 22, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            AIDJTransitionBadgeView(
                incomingTrack: player.incomingTrack,
                phaseLabel: player.mashupPhaseLabel
            )
            .transition(.opacity)
        } else if let stem = stemBadgeText(analysis.stemStatus) {
            Text(stem)
                .font(SN.text(.caption2, .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .transition(.opacity)
        } else {
            qualityBadgeButton
                .transition(.opacity)
        }
    }
    /// Progress while stems are counted. A failed Core ML load must not replace the quality badge.
    private func stemBadgeText(_ stem: String?) -> String? {
        guard let stem, !stem.isEmpty else { return nil }
        let folded = stem.lowercased()
        if stem.hasPrefix("HTDemucs · скрыть") || stem == "HTDemucs · готово" { return nil }
        if folded.contains("file://") || folded.contains("unable to load") || folded.contains("private/var") {
            return nil
        }
        return stem
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
    private var qualityBadgeIcon: String { "waveform" }
    private var qualityBadgeLabel: String {
        PlaybackQualityFacts(codec: player.currentCodec, bitrate: player.currentBitrate).badge
    }
    private func transportControls(coverWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap(.light)
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(player.shuffle ? SN.amber : SN.ink.opacity(0.55))
                    .frame(width: 44, height: 56)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(player.shuffle ? "Перемешивание включено" : "Перемешать")

            Button { animateTrackSwipe(direction: -1, width: coverWidth) } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 56, height: 52)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .offset(x: player.isPlaying ? 0 : 2)
                    .contentTransition(.symbolEffect(.replace.byLayer))
                    .frame(width: 60, height: 56)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .disabled(player.isLoading)

            Button { animateTrackSwipe(direction: 1, width: coverWidth) } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 56, height: 52)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)

            Button {
                Haptics.tap(.light)
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(player.repeatMode != .off ? SN.amber : SN.ink.opacity(0.55))
                    .frame(width: 44, height: 56)
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
                            player.reportWaveDislike(current, isDisliked: false)
                            UserTasteEngine.shared.removeDislike(track: current)
                            waveMessage = "Трек снова может появиться в волне"
                        } else {
                            player.reportWaveDislike(current, isDisliked: true)
                            UserTasteEngine.shared.recordDislike(track: current)
                            MoodRadioEngine.shared.recordFeedback(track: current, action: .dislike)
                            waveMessage = "Дизлайк учтён для рекомендаций"
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
                let waveAvailability = trackWaveMenuAvailability
                Button {
                    startTrackWave()
                } label: {
                    Label(
                        waveLoading
                            ? "Настраиваем волну…"
                            : (waveAvailability.active
                                ? "Моя волна по треку · активна"
                                : "Моя волна по текущему треку"),
                        systemImage: waveAvailability.active ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right"
                    )
                }
                .disabled(!waveAvailability.catalog || waveLoading)

                Button {
                    startAIVibeWave()
                } label: {
                    Label("AI Вайб-волна (похожие по вайбу)", systemImage: "sparkles")
                }
                .disabled(track == nil || waveLoading || AIDJService.shared.isVibeWaveGenerating)

                Toggle("Видеошоты", isOn: $isVideoShotEnabled)
                if videoShotURL != nil {
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
                Button {
                    // Same Menu→chrome race as sheets: wait for the menu to dismiss first.
                    scheduleAfterMenuDismiss {
                        withAnimation(LyricsPresentationMotion.animation(reduceMotion: reduceMotion)) { showLyricsMode.toggle() }
                    }
                } label: {
                    Label("Текст песни", systemImage: "quote.bubble")
                }

                Button { openModal(.queue, deferForMenu: true) } label: {
                    Label("Очередь", systemImage: "list.bullet")
                }
                Button { openModal(.equalizer, deferForMenu: true) } label: {
                    Label { Text("Эквалайзер") } icon: { SonivoEqualizerGlyph(size: 20).foregroundStyle(SN.accent) }
                }
                Button { openModal(.sleepTimer, deferForMenu: true) } label: {
                    if let timerText = player.sleepTimerFormatted {
                        Label("Таймер сна (\(timerText))", systemImage: "moon.zzz.fill")
                    } else {
                        Label("Таймер сна", systemImage: "moon.zzz")
                    }
                }
                Button { openModal(.settings, deferForMenu: true) } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
            }

            Section {
                Button {
                    AutoMixSessionLog.shared.copyReportToClipboard()
                    waveMessage = "✅ Лог AutoMix скопирован — вставь в чат"
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if waveMessage?.contains("Лог AutoMix") == true { waveMessage = nil }
                    }
                } label: {
                    Label("Скопировать лог AutoMix", systemImage: "doc.on.clipboard")
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
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(SN.ink.opacity(0.90))
                .frame(width: tapSide, height: tapSide)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ещё")
    }

    private var artistSelectionSheet: some View {
        List(artistChoices) { artist in
            Button(artist.name) {
                let chosen = artist
                activeModal = nil
                // Dismiss the picker sheet first so the artist window can present cleanly.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    selectedArtist = chosen
                }
            }
        }
            .navigationTitle("Исполнители").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
    }

    private func updatePalette(from image: UIImage, trackID: UUID) async {
        let (hexes, tone) = await Task.detached(priority: .utility) {
            (LibraryStore.artworkPalette(from: image), PlayerArtworkTone.extract(image))
        }.value
        guard !Task.isCancelled, track?.id == trackID, paletteTrackId == trackID else { return }
        let colors = hexes.compactMap(Color.init(hex:)); guard !colors.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.85)) {
            artworkPaletteColors = colors
            dominantArtworkColor = tone.map { Color(.sRGB, red: Double($0.x), green: Double($0.y), blue: Double($0.z), opacity: 1) }
            resolvedArtworkPaletteTrackID = trackID
        }
    }
    private func refreshPalette() async {
        guard let track, paletteTrackId != track.id || resolvedArtworkPaletteTrackID != track.id else { return }
        paletteTrackId = track.id
        if artworkTrackId != track.id { currentArtworkImage = nil }
        artworkTrackId = track.id
        if let image = LibraryStore.cachedArtworkImage(for: track) {
            currentArtworkImage = image
            await updatePalette(from: image, trackID: track.id)
        } else if let raw = track.coverURL, let url = URL(string: raw), let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
            LibraryStore.cachePlayerArtwork(image, for: track)
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
                    LibraryStore.cachePlayerArtwork(img, for: next)
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
            self.lyrics = verified
            self.cachedPhrases = verified.isSynchronized ? LyricPhrase.from(lines: verified.lines) : []
            SonivoDiagnostics.log("Lyrics loaded: source=\(verified.sourceName), lines=\(verified.lines.count), wordSync=\(verified.hasDynamicWordTimings), sourceOffset=\(verified.offset)", tag: "LYRICS")
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
        guard isVideoShotEnabled, !reduceMotion, let track else {
            SonivoDiagnostics.log("Load skipped: enabled=\(isVideoShotEnabled), reduceMotion=\(reduceMotion), hasTrack=\(track != nil)", tag: "VIDEOSHOT")
            return
        }
        let requestedTrackID = track.id
        let id = PlayerCore.yandexTrackID(from: track)

        var url: URL? = nil
        SonivoDiagnostics.log("Resolving video: stream=\(track.isStream), signedIn=\(YandexMusicService.shared.isUserLoggedIn), hasCatalogID=\(!id.isEmpty)", tag: "VIDEOSHOT")

        // 1. ПРИОРИТЕТ 1: Локальный кэш устройства и встроенные видео в App Bundle (работает всегда 24/7 офлайн, когда ПК выключен)
        url = AIVideoShotGeneratorService.shared.localVideoShotURL(for: id, title: track.title, artist: track.artist)

        // 2. ПРИОРИТЕТ 2: Официальный видео-шот из Yandex Music (по LTE/5G/Wi-Fi)
        if url == nil && track.isStream && YandexMusicService.shared.isUserLoggedIn && !id.isEmpty {
            if let ymURL = await YandexMusicService.shared.getVideoShotUrl(for: id) {
                url = ymURL
            }
        }

        guard !Task.isCancelled, isVideoShotEnabled, !reduceMotion,
              self.track?.id == requestedTrackID, player.currentTrack?.id == requestedTrackID else { return }
        SonivoDiagnostics.log(url == nil ? "No video URL resolved" : "Video URL resolved; preparing native player", tag: "VIDEOSHOT")
        videoShotURL = url
        videoShotTrackID = requestedTrackID
        if isVideoShotEnabled, let url {
            setupVideoLooper(url: url)
        }
    }
    private func setupVideoLooper(url: URL) {
        videoPlayback.configure(url: url)
        updateVideoPlayback()
    }
    private func teardownVideoLooper() {
        videoPlayback.teardown()
    }
    private var videoLoadKey: VideoShotLoadKey {
        VideoShotLoadKey(trackID: track?.id, playbackTrackID: player.currentTrack?.id,
                         enabled: isVideoShotEnabled, reduceMotion: reduceMotion,
                         accountGeneration: YandexMusicService.shared.accountGeneration)
    }

    private func updateVideoPlayback() {
        videoPlayback.update(enabled: isVideoShotEnabled, matchingTrack: videoShotTrackID == track?.id,
                             musicPlaying: player.isPlaying, sceneActive: scenePhase == .active,
                             playerVisible: isPresented, lyricsVisible: showLyricsMode, reduceMotion: reduceMotion)
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
                if isVideoShotEnabled && !reduceMotion { setupVideoLooper(url: url) }
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
    private func openModal(_ modal: ActivePlayerModal, deferForMenu: Bool = false) {
        Haptics.tap(.light)
        if deferForMenu {
            // Menu dismissal fights an immediate `.sheet` — match the artist-picker
            // 320 ms handoff so EQ/queue/settings do not flash then bounce closed.
            scheduleAfterMenuDismiss { activeModal = modal }
        } else {
            pendingModalTask?.cancel()
            activeModal = modal
        }
    }

    private func scheduleAfterMenuDismiss(_ action: @escaping @MainActor () -> Void) {
        pendingModalTask?.cancel()
        pendingModalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, isPresented else { return }
            action()
        }
    }
    private func togglePlayback() { Haptics.tap(.medium); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.togglePlay() }
    private func animateTrackSwipe(direction: Int, width: CGFloat) {
        guard !isCoverSwitching else { return }
        coverSwitchTask?.cancel()
        coverSettleTask?.cancel()
        let generation = UUID()
        coverSwitchGeneration = generation
        isCoverSwitching = true
        let outgoing = track
        let previousNeighbors = coverSwipeNeighbors
        let outgoingImage = outgoing.flatMap { artworkImage(for: $0) }
        let canAnimate = !reduceMotion && !showLyricsMode && !isFullScreenVideoShot
            && coverMixAmount == 0 && width.isFinite && width > 0
        Haptics.tap(.light)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        // Playback must never wait for a visual effect. Capture what the engine
        // actually selected (including shuffle/radio) and animate that result.
        if direction > 0 { player.next() } else { player.previous() }
        guard canAnimate, let outgoing, let incoming = player.currentTrack,
              incoming.id != outgoing.id else {
            settleCoverDrag()
            releaseCoverSwitchLock()
            return
        }
        coverTransitionOutgoing = outgoing
        coverTransitionIncoming = incoming
        coverTransitionOther = direction > 0 ? previousNeighbors.prev : previousNeighbors.next
        coverTransitionOutgoingImage = outgoingImage
        coverTransitionDirection = direction
        coverVisualSide = direction > 0 ? 1 : -1
        // A button starts at rest; mount the destination plate before animating.
        if abs(coverDragX) < 0.5 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let initial = max(1, width * 0.004)
            withTransaction(transaction) { coverDragX = direction > 0 ? -initial : initial }
        }
        let distance = width * CoverFoldSwipeMath.clusterFactor
        let targetX: CGFloat = direction > 0 ? -distance : distance
        coverSwitchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard !Task.isCancelled, coverSwitchGeneration == generation else { return }
            guard isPresented, player.currentTrack?.id == incoming.id else { cancelCoverSwitch(); return }
            withAnimation(CoverFoldSwipeMotion.commitAnimation) { coverDragX = targetX }
            do { try await Task.sleep(for: .milliseconds(CoverFoldSwipeMotion.commitHoldMilliseconds)) } catch { return }
            guard !Task.isCancelled, coverSwitchGeneration == generation else { return }
            guard isPresented, player.currentTrack?.id == incoming.id else { cancelCoverSwitch(); return }
            finishCoverSwitch()
        }
    }
    private func settleCoverDrag() {
        coverSettleTask?.cancel()
        withAnimation(reduceMotion ? nil : CoverFoldSwipeMotion.cancelAnimation) { coverDragX = 0 }
        if reduceMotion { coverVisualSide = 0; return }
        coverSettleTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
            guard !Task.isCancelled else { return }
            coverVisualSide = 0
            coverSettleTask = nil
        }
    }
    private func finishCoverSwitch() {
        coverSettleTask?.cancel()
        coverSettleTask = nil
        coverSwitchTask = nil
        isCoverSwitching = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            coverDragX = 0
            coverTransitionOutgoing = nil
            coverTransitionIncoming = nil
            coverTransitionOther = nil
            coverTransitionOutgoingImage = nil
            coverTransitionDirection = 0
            coverVisualSide = 0
        }
    }
    private func cancelCoverSwitch() {
        coverSwitchTask?.cancel()
        coverSwitchGeneration = UUID()
        finishCoverSwitch()
    }
    private func releaseCoverSwitchLock() {
        let generation = UUID()
        coverSwitchGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard coverSwitchGeneration == generation else { return }
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


}

// MARK: - Cover Lyrics Continuous Scroll View (Сплошной текст с плавной автопрокруткой)

struct CoverLyricsScrollView: View {
    let lyrics: Lyrics
    let player: ActivePlayerPresentation
    let side: CGFloat
    @State private var settings = SettingsStore.shared
    @State private var isUserInteracting = false
    @State private var interactionResetTask: Task<Void, Never>? = nil
    @State private var frameClock = LyricsDisplayClock()
    private var activeIndex: Int? { frameClock.activeIndex }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TypographyLyricsView(lyrics: lyrics, player: player, showsSource: false, compact: true)
            .frame(maxWidth: side, maxHeight: side)
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
                                    player.seek(to: LyricsPlaybackClock.seekTime(lineStart: line.startTime))
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
            .onChange(of: activeIndex) { _, index in
                if let index, !isUserInteracting {
                    LyricsFocusMotion.scroll(reduceMotion: reduceMotion) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let activeIndex { proxy.scrollTo(activeIndex, anchor: .center) }
            }
        }
        .background { LyricsClockSurface(clock: frameClock, player: player, lyrics: lyrics) }
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
                .font(KaraokeTypography.font(size: 28))
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
        .transaction { $0.animation = nil }
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
    @State private var scrubStartFraction = 0.0
    @State private var scrubTrackID: UUID?
    @State private var scrubRejected = false
    @GestureState private var scrubContact = false
    @State private var pendingSeekProgress: Double?
    @State private var lastFeedbackProgress = 0.0
    /// Tracks Automix display-track hard cut so the bar snaps without easing.
    @State private var timelineIdentity: UUID?
    private let feedback = UISelectionFeedbackGenerator()
    private let center: Center
    init(player: ActivePlayerPresentation, @ViewBuilder center: () -> Center) {
        self.player = player
        self.center = center()
    }
    private var mixing: Bool { player.isTransitionActive }
    /// While scrubbing/seeking during Automix, stay on the live outgoing deck
    /// so B's handoff snap cannot remap the scrub target.
    private var timelineDuration: Double {
        if isScrubbing || pendingSeekProgress != nil {
            return max(player.scrubDuration, 0.01)
        }
        return max(player.duration, 0.01)
    }
    private var effectiveProgress: Double {
        if isScrubbing { return scrubProgress }
        if let pending = pendingSeekProgress { return pending }
        return player.progress
    }
    /// Apple Automix: the bar always follows the real track clock (A until LAND,
    /// then B). Never replace it with a separate mashup 0→1 meter.
    private var barFraction: Double {
        min(1, max(0, effectiveProgress / timelineDuration))
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let duration = timelineDuration
                let fraction = barFraction
                let width = geo.size.width * fraction
                // Scrub stays live during Automix; seek cancels the mashup.
                // Apple Music: thin seek capsule; thumb only while scrubbing.
                let trackHeight: CGFloat = isScrubbing ? 6 : 3
                let thumbSize: CGFloat = 14

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isScrubbing ? 0.28 : 0.22))
                        .frame(height: trackHeight)

                    if let bufferFraction = player.bufferedProgress, bufferFraction > 0.005, !mixing {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(isScrubbing ? 0.40 : 0.32))
                            .frame(
                                width: max(trackHeight, geo.size.width * min(1.0, CGFloat(bufferFraction))),
                                height: trackHeight
                            )
                            .animation(.easeInOut(duration: 0.2), value: bufferFraction)
                    }

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(mixing ? 1.0 : 0.92))
                        .frame(width: max(0, width), height: trackHeight)
                        // Hard snap on Automix handoff (display track / duration change) — no morph.
                        .transaction { tx in
                            if mixing && !isScrubbing { tx.animation = nil }
                        }

                    if isScrubbing {
                        Circle()
                            .fill(Color.white)
                            .frame(width: thumbSize, height: thumbSize)
                            .offset(x: max(0, min(width - thumbSize / 2, geo.size.width - thumbSize)))
                            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    }
                }
                .animation(.smooth(duration: 0.18), value: isScrubbing)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($scrubContact) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !scrubRejected, timelineDuration > 0 else { return }
                            if !isScrubbing {
                                guard PlayerInteractionPolicy.horizontalIntent(x: Double(value.translation.width), y: Double(value.translation.height)) else {
                                    scrubRejected = true; return
                                }
                                let liveDuration = max(player.scrubDuration, 0.01)
                                scrubStartFraction = min(1, max(0, player.scrubProgress / liveDuration))
                                // Anchor to the playing (outgoing) track while mashup runs —
                                // seek cancels Automix and stays on that deck.
                                scrubTrackID = player.currentTrack?.id ?? player.displayTrack?.id
                                lastFeedbackProgress = scrubStartFraction
                                isScrubbing = true
                                feedback.prepare()
                            }
                            let f = PlayerInteractionPolicy.draggedFraction(start: scrubStartFraction,
                                translation: Double(value.translation.width), width: Double(geo.size.width))
                            scrubProgress = f * timelineDuration
                            if abs(f - lastFeedbackProgress) > 0.04 {
                                Haptics.scrubTick(feedback)
                                lastFeedbackProgress = f
                            }
                        }
                        .onEnded { value in
                            defer { isScrubbing = false; scrubRejected = false }
                            guard isScrubbing, !scrubRejected, timelineDuration > 0 else { return }
                            let f = PlayerInteractionPolicy.draggedFraction(start: scrubStartFraction,
                                translation: Double(value.translation.width), width: Double(geo.size.width))
                            let target = f * timelineDuration
                            pendingSeekProgress = target
                            // seek(to:) cancels an in-flight Automix mashup.
                            player.seek(to: target)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                if pendingSeekProgress == target { pendingSeekProgress = nil }
                            }
                        }
                )
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Позиция воспроизведения")
            .accessibilityValue(
                "\(player.formatted(effectiveProgress)) из \(player.formatted(timelineDuration))"
            )
            .accessibilityAdjustableAction { direction in
                let duration = player.scrubDuration
                let position = player.scrubProgress
                let step = max(5, duration * 0.02)
                switch direction {
                case .increment:
                    player.seek(to: min(position + step, duration))
                case .decrement:
                    player.seek(to: max(position - step, 0))
                @unknown default:
                    break
                }
            }

            // Apple layout: elapsed | Mixing | remaining — same track clock as the bar.
            HStack {
                Text(player.formatted(effectiveProgress))
                    .font(SN.text(.caption2, .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.62))
                    .contentTransition(.numericText())
                Spacer()
                center
                Spacer()
                Text("-" + player.formatted(max(0, timelineDuration - effectiveProgress)))
                    .font(SN.text(.caption2, .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.62))
                    .contentTransition(.numericText())
            }
        }
        .onChange(of: scrubContact) { _, active in
            if !active { isScrubbing = false; scrubRejected = false }
        }
        .onChange(of: player.displayTrack?.id) { _, newID in
            // Don't abort an in-progress scrub when Automix snaps metadata to B.
            if !isScrubbing {
                scrubRejected = scrubContact
                pendingSeekProgress = nil
            }
            timelineIdentity = newID
        }
        .onChange(of: player.progress) { _, newProgress in
            if let pending = pendingSeekProgress, abs(newProgress - pending) < 1.0 {
                pendingSeekProgress = nil
            }
        }
        .onChange(of: player.isTransitionActive) { _, active in
            // Mashup start shouldn't kill a scrub mid-gesture; seek end cancels mix.
            if active && !isScrubbing {
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
    @State private var volumeStartFraction = 0.0
    @State private var volumeRejected = false
    @GestureState private var volumeContact = false

    var body: some View {
        // Apple Music: thicker pill volume, no resting thumb — fill only.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 18, height: 18, alignment: .center)

            GeometryReader { geo in
                let width = geo.size.width
                let currentVol = volumeManager.volume
                let progress = CGFloat(max(0.0, min(1.0, currentVol)))
                let filledWidth = width * progress
                let trackHeight: CGFloat = isDragging ? 10 : 7

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(isDragging ? 0.28 : 0.22))
                        .frame(height: trackHeight)

                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: max(trackHeight, filledWidth), height: trackHeight)
                }
                .animation(.smooth(duration: 0.16), value: isDragging)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .updating($volumeContact) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !volumeRejected else { return }
                            if !isDragging {
                                guard PlayerInteractionPolicy.horizontalIntent(x: Double(value.translation.width), y: Double(value.translation.height)) else {
                                    volumeRejected = true; return
                                }
                                volumeStartFraction = Double(volumeManager.volume)
                                isDragging = true
                                Haptics.tap(.light)
                            }
                            let fraction = PlayerInteractionPolicy.draggedFraction(start: volumeStartFraction,
                                translation: Double(value.translation.width), width: Double(width))
                            volumeManager.setVolume(Float(fraction))
                        }
                        .onEnded { value in
                            defer { isDragging = false; volumeRejected = false }
                            guard isDragging, !volumeRejected else { return }
                            let fraction = PlayerInteractionPolicy.draggedFraction(start: volumeStartFraction,
                                translation: Double(value.translation.width), width: Double(width))
                            volumeManager.setVolume(Float(fraction))
                        }
                )
            }
            .frame(height: 36)
            .background(InvisibleVolumeView().frame(width: 60, height: 20).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true))

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 20, height: 18, alignment: .center)
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .onAppear { volumeManager.refreshFromSystem() }
        .onChange(of: volumeContact) { _, active in
            if !active { isDragging = false; volumeRejected = false }
        }
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
        // Spectrum/timeline updates must not rebind an unchanged AVPlayerLayer.
        if uiView.videoGravity != videoGravity { uiView.videoGravity = videoGravity }
        if uiView.player !== player { uiView.player = player }
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

                Text(player.spatialAudioStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SN.amber)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
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

    private var qualitySettingsList: some View {
        List {
            Section {
                Toggle("Системное пространственное аудио", isOn: $player.spatialAudioEnabled)
            } header: {
                Text("Пространственное аудио")
            } footer: {
                Text("Разрешает системную обработку iOS. Режим «Фиксированное» или «Отслеживание головы» выбирается в Пункте управления. Собственного объёмного эффекта нет.")
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
            Section("Диагностика") {
                Button("Скопировать диагностику качества") {
                    UIPasteboard.general.string = YandexMusicService.shared.streamQualityReport()
                    Haptics.tap(.light)
                }
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

    private var currentQuality: PlaybackQualityFacts {
        PlaybackQualityFacts(codec: player.currentCodec, bitrate: player.currentBitrate)
    }
    private var currentQualityTitle: String { currentQuality.title }
    private var currentQualityDescription: String {
        let requestedLossless = player.audioQuality == .lossless || player.audioQuality == .hiResLossless
        if requestedLossless && currentQuality.isLossy {
            return "Выбрано «Без потерь», но для текущего воспроизведения Lossless не получен. Используется источник с потерями. Это не Lossless."
        }
        return currentQuality.description
    }
    private var currentQualityFormatDetail: String? { currentQuality.detail }

}

// MARK: - Now Playing atmosphere (Apple Music style)
//
// Full-bleed UIBlur wash behind the dissolving edge-to-edge cover. Top stays
// relatively clear so the sharp art reads; bottom darkens into frosted controls.

private struct NowPlayingAtmosphere: UIViewRepresentable {
    var primary: UIImage?
    var secondary: UIImage?
    var secondaryAmount: CGFloat

    func makeUIView(context: Context) -> NowPlayingAtmosphereView {
        NowPlayingAtmosphereView()
    }

    func updateUIView(_ view: NowPlayingAtmosphereView, context: Context) {
        view.primaryImage = primary
        view.secondaryImage = secondary
        view.secondaryAmount = secondaryAmount
    }
}

private final class NowPlayingAtmosphereView: UIView {
    private let primaryView = UIImageView()
    private let secondaryView = UIImageView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let dimView = UIView()
    private let topClear = CAGradientLayer()
    private let bottomFade = CAGradientLayer()

    var primaryImage: UIImage? {
        didSet { if primaryView.image !== primaryImage { primaryView.image = primaryImage } }
    }
    var secondaryImage: UIImage? {
        didSet { if secondaryView.image !== secondaryImage { secondaryView.image = secondaryImage } }
    }
    var secondaryAmount: CGFloat = 0 {
        didSet { if oldValue != secondaryAmount { applyAlphas() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = .black
        for imageView in [primaryView, secondaryView] {
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            addSubview(imageView)
        }
        blurView.isUserInteractionEnabled = false
        addSubview(blurView)
        // Light dim — leave room for the SwiftUI coverAccentWash palette bloom.
        dimView.isUserInteractionEnabled = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        addSubview(dimView)
        // Feather only — native blur stays colorful under the cover's soft top dissolve.
        topClear.colors = [
            UIColor.black.withAlphaComponent(0.04).cgColor,
            UIColor.clear.cgColor
        ]
        topClear.locations = [0.0, 1.0]
        // Soft downward darkening; keep mid wash colorful, not crushed to black.
        bottomFade.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.18).cgColor,
            UIColor.black.withAlphaComponent(0.42).cgColor,
            UIColor.black.withAlphaComponent(0.62).cgColor
        ]
        bottomFade.locations = [0.0, 0.48, 0.74, 1.0]
        layer.addSublayer(topClear)
        layer.addSublayer(bottomFade)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Overscan so aspect-fill never flashes edges during Automix crossfade.
        let overscan = bounds.insetBy(dx: -bounds.width * 0.06, dy: -bounds.height * 0.06)
        primaryView.frame = overscan
        secondaryView.frame = overscan
        blurView.frame = bounds
        dimView.frame = bounds
        topClear.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.16)
        bottomFade.frame = bounds
        applyAlphas()
    }

    private func applyAlphas() {
        let incoming = min(1, max(0, secondaryAmount))
        if secondaryImage == nil {
            secondaryView.alpha = 0
            primaryView.alpha = primaryImage == nil ? 0 : 1
        } else {
            secondaryView.alpha = incoming
            primaryView.alpha = 1 - incoming
        }
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
