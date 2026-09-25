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
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var coverDragX: CGFloat = 0
    @State private var isCoverSwitching = false
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String?
    @State private var videoShotURL: URL?
    @State private var isVideoShotEnabled = UserDefaults.standard.object(forKey: "aurora_videoshot_enabled") as? Bool ?? true
    @State private var videoLooperPlayer: AVQueuePlayer?
    @State private var videoLooper: AVPlayerLooper?
    @State private var videoShotTrackID: UUID?
    @State private var artworkPaletteColors: [Color] = []
    @State private var paletteTrackId: UUID?
    @State private var artworkTrackId: UUID?
    @State private var currentArtworkImage: UIImage?
    @State private var cachedPhrases: [LyricPhrase] = []
    private let tapSide: CGFloat = AG.tapTarget

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
            let artworkTopOffset = topInset + 44
            let artworkStageHeight = isFullScreenVideoShot
                ? (totalHeight * 0.55)
                : min(totalWidth - 40, totalHeight * 0.44)

            ZStack(alignment: .top) {
                background
                    .frame(width: totalWidth, height: totalHeight)
                    .clipped()

                artworkStage(width: totalWidth, height: artworkStageHeight)
                    .frame(width: totalWidth, height: artworkStageHeight, alignment: .center)
                    .padding(.top, artworkTopOffset)

                // Soft blurred top gradient fade under Dynamic Island
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.80),
                        Color.black.opacity(0.35),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(geo.safeAreaInsets.top, 50) + 16)
                .ignoresSafeArea(edges: .top)

                VStack(spacing: 0) {
                    topHeader
                        .padding(.top, max(geo.safeAreaInsets.top, 50))
                        .padding(.horizontal, 20)

                    Spacer(minLength: 0)

                    if let waveMessage {
                        Text(waveMessage)
                            .font(AG.text(.caption, .semibold))
                            .foregroundStyle(AG.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .glassCapsule()
                            .padding(.bottom, 6)
                    }

                    lowerDeck(safeAreaBottom: geo.safeAreaInsets.bottom)
                }
            }
            .frame(width: totalWidth, height: totalHeight, alignment: .top)
        }
        .ignoresSafeArea()
        .background(AG.bg.ignoresSafeArea())
        .simultaneousGesture(DragGesture().onEnded { value in
            if value.translation.height > 80 && value.predictedEndTranslation.height > 120 { close() }
        })
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
            videoShotURL = nil
            videoShotTrackID = nil
            teardownVideoLooper()
        }
        .onDisappear {
            teardownVideoLooper()
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
                let bgImg = currentArtworkImage ?? track.flatMap { LibraryStore.cachedArtworkImage(for: $0) }
                if let bgImg {
                    Image(uiImage: bgImg)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .blur(radius: 12)
                        .scaleEffect(1.08)
                        .opacity(0.28)
                        .clipped()
                        .drawingGroup()
                } else {
                    gradientBackground
                }
                AnimatedMeshBackground(palette: Array(backgroundColors.prefix(3))).opacity(0.25)
                LinearGradient(stops: [.init(color: .black.opacity(0.10), location: 0),
                                        .init(color: .black.opacity(0.35), location: 0.50),
                                        .init(color: .black.opacity(0.85), location: 1.0)],
                                startPoint: .top, endPoint: .bottom)
            }
        }.allowsHitTesting(false)
    }
    private var backgroundColors: [Color] { palette.isEmpty ? [AG.amber, AG.ember] : palette }
    private var gradientBackground: some View {
        let colors = backgroundColors
        return LinearGradient(colors: [colors[0].opacity(0.65), colors[min(1, colors.count - 1)].opacity(0.38), .black],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var topHeader: some View {
        VStack(spacing: 5) {
            Capsule()
                .fill(Color.white.opacity(0.32))
                .frame(width: 36, height: 4.5)
                .padding(.top, 4)

            Text("СЕЙЧАС ИГРАЕТ")
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(1.0)
                .foregroundStyle(AG.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .contentShape(Rectangle())
    }

    private func artworkStage(width: CGFloat, height: CGFloat) -> some View {
        let cardSide = min(width - 40, height)
        return ZStack {
            if isFullScreenVideoShot {
                // В полноэкранном режиме видеошота обложка не закрывает видео даже при включении текста!
                Color.clear
                    .frame(width: width, height: height)
            } else if !showLyricsMode {
                artwork
                    .frame(width: cardSide, height: cardSide)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                AutoMixTransitionOverlay(player: player, width: width, height: height)
            } else {
                lyricsCoverCard(side: cardSide)
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(player.isPlaying ? 1.0 : 0.96)
        .offset(x: coverDragX)
        .contentShape(Rectangle())
        .gesture(
            showLyricsMode ? nil : DragGesture(minimumDistance: 15)
                .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                coverDragX = value.translation.width / (1 + abs(value.translation.width) * 0.001)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { coverDragX = 0 }; return
                }
                let threshold: CGFloat = 65
                if value.translation.width < -threshold, !isCoverSwitching {
                    Haptics.tap(.light)
                    withAnimation(.easeOut(duration: 0.16)) {
                        coverDragX = -width * 1.15
                    }
                    nextTrack()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        coverDragX = width * 0.85
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            coverDragX = 0
                        }
                    }
                } else if value.translation.width > threshold, !isCoverSwitching {
                    Haptics.tap(.light)
                    withAnimation(.easeOut(duration: 0.16)) {
                        coverDragX = width * 1.15
                    }
                    previousTrack()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        coverDragX = -width * 0.85
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            coverDragX = 0
                        }
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { coverDragX = 0 }
                }
            })
        .animation(.easeInOut(duration: 0.35), value: player.isTransitionActive)
        .animation(AG.slowSpring, value: player.isPlaying)
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
                        .font(AG.text(.subheadline, .medium))
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
            .buttonStyle(TactileButtonStyle(scale: 0.88))
            .padding(10)
            .accessibilityLabel("Развернуть текст песни на весь экран")

            // 4. Оверлей управления вокалом (караоке-режим / Apple Music Sing style)
            if isVocalToggleVisible {
                VocalIsolationControlView()
                    .padding(VocalIsolationUIConfig.cornerPadding)
                    .frame(maxWidth: side, maxHeight: side, alignment: VocalIsolationUIConfig.cornerAlignment)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private var currentLyricsPair: (current: String, next: String?) {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return ("Слова песни", nil) }
        let targetTime = max(0, player.progress + SettingsStore.shared.lyricsOffset)
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
        VStack(spacing: 12) {
            metadataRow
            PlayerTimelineSection(player: player) { centerStatusLabel }
            transportControls
            FluidVolumeSlider()
            .accessibilityElement(children: .contain)
            HStack {
                GlassIconButton(systemImage: showLyricsMode ? "quote.bubble.fill" : "quote.bubble", tint: showLyricsMode ? AG.amber : AG.inkMuted, accessibilityLabel: "Текст песни") { withAnimation(AG.spring) { showLyricsMode.toggle() } }
                Spacer()
                GlassIconButton(systemImage: "slider.vertical.3", tint: player.eqEnabled ? AG.amber : AG.inkMuted, accessibilityLabel: "Эквалайзер") { openModal(.equalizer) }
                Spacer()
                AirPlayButtonView().frame(width: tapSide, height: tapSide).glassCircle()
                Spacer()
                GlassIconButton(systemImage: "list.bullet", tint: AG.inkMuted, accessibilityLabel: "Очередь") { openModal(.queue) }
            }.padding(.horizontal, 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, max(safeAreaBottom, 20))
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(0.16))
                if let tint = palette.first {
                    tint.opacity(0.12)
                }
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.14),
                        .init(color: .black.opacity(0.30), location: 0.38),
                        .init(color: .black.opacity(0.68), location: 0.70),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
    private var metadataRow: some View {
        let current = track
        return HStack(spacing: 12) {
            Button(action: openArtist) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: current?.title ?? "Не играет", font: AG.rounded(.title2, .bold), color: AG.ink, height: 28)
                    MarqueeText(text: current?.artist ?? "", font: AG.rounded(.body, .medium), color: AG.inkMuted, height: 22)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(current == nil || resolvingArtist)

            HStack(spacing: 10) {
                if videoShotURL != nil {
                    GlassIconButton(
                        systemImage: isVideoShotEnabled ? "video.fill" : "video.slash.fill",
                        tint: isVideoShotEnabled ? AG.positive : AG.inkMuted,
                        accessibilityLabel: "Видео-шот",
                        action: toggleVideoShot
                    )
                }

                if current != nil {
                    GlassIconButton(
                        systemImage: "dot.radiowaves.left.and.right",
                        tint: waveActive ? AG.amber : AG.inkMuted,
                        accessibilityLabel: "Моя волна по треку",
                        action: startTrackWave
                    )
                    .disabled(waveLoading)
                }

                if let current {
                    let disliked = UserTasteEngine.shared.isDisliked(track: current)
                    Menu {
                        if disliked {
                            Button {
                                UserTasteEngine.shared.removeDislike(track: current)
                                waveMessage = "Трек снова может появиться в волне"
                            } label: {
                                Label("Отменить дизлайк", systemImage: "arrow.uturn.backward")
                            }
                        } else {
                            Button(role: .destructive) {
                                UserTasteEngine.shared.recordDislike(track: current)
                                MoodRadioEngine.shared.recordFeedback(track: current, action: .dislike)
                                waveMessage = "Трек исключён из Моей волны"
                                player.next()
                            } label: {
                                Label("Не рекомендовать", systemImage: "hand.thumbsdown")
                            }
                        }
                    } label: {
                        Image(systemName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .foregroundStyle(disliked ? AG.heart : AG.inkMuted)
                            .frame(width: tapSide, height: tapSide)
                    }
                    .glassCircle()
                    .accessibilityLabel(disliked ? "Отменить дизлайк" : "Не рекомендовать этот трек")
                }
            }
        }
    }
    @ViewBuilder private var centerStatusLabel: some View {
        if player.isTransitionActive {
            AutoMixBadge().transition(.opacity)
        } else {
            qualityBadgeButton.transition(.opacity)
        }
    }
    private var qualityBadgeButton: some View {
        Button { openModal(.quality) } label: {
            HStack(spacing: 4) { Image(systemName: "waveform"); Text(qualityBadgeLabel) }
                .font(AG.text(.caption2, .semibold)).foregroundStyle(AG.ink.opacity(0.85)).padding(.horizontal, 10).padding(.vertical, 6)
        }.buttonStyle(.plain).glassCapsule(interactive: true)
    }
    private var qualityBadgeLabel: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
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
                guard let current = track else { return }
                library.toggleFavorite(current)
            } label: {
                let favorite = track.map(library.isTrackFavorite) ?? false
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(favorite ? AG.heart : AG.inkMuted)
                    .frame(width: 48, height: 48)
            }
            .frame(maxWidth: .infinity)
            .disabled(track == nil)
            .accessibilityLabel(track.map(library.isTrackFavorite) == true ? "Убрать из избранного" : "В избранное")

            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .black))
                    .foregroundStyle(AG.ink)
                    .frame(width: 66, height: 66)
                    .contentShape(Circle())
            }
            .glassCircle()
            .frame(maxWidth: .infinity)
            .disabled(player.isLoading)

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }

            moreMenuButton
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(AG.ink)
        .buttonStyle(TactileButtonStyle(scale: 0.88))
    }

    private var moreMenuButton: some View {
        Menu {
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

            Divider()

            Button { withAnimation(AG.spring) { showLyricsMode.toggle() } } label: {
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
                Label("Таймер сна", systemImage: "timer")
            }
            Button { openModal(.settings) } label: {
                Label("Настройки", systemImage: "gearshape")
            }

            Divider()

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
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(AG.inkMuted)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .accessibilityLabel("Ещё")
    }

    private var artistSelectionSheet: some View {
        List(artistChoices) { artist in Button(artist.name) { activeModal = nil; selectedArtist = artist } }
            .navigationTitle("Исполнители").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
    }

    private func updatePalette(from image: UIImage) async {
        let hexes = await Task.detached(priority: .utility) { LibraryStore.artworkPalette(from: image) }.value
        let colors = hexes.compactMap(Color.init(hex:)); guard !colors.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.85)) { artworkPaletteColors = colors }
    }
    private func refreshPalette() async {
        guard let track, paletteTrackId != track.id else { return }
        paletteTrackId = track.id
        artworkTrackId = track.id
        if let image = LibraryStore.cachedArtworkImage(for: track) {
            currentArtworkImage = image
            await updatePalette(from: image)
        } else if let raw = track.coverURL, let url = URL(string: raw), let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
            LibraryStore.cacheArtworkImage(image, for: track)
            if paletteTrackId == track.id {
                currentArtworkImage = image
                await updatePalette(from: image)
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
        lyricsLoading = true
        var result = try? await LyricsService.shared.fetchLyrics(for: requested)
        guard !Task.isCancelled, player.currentTrack?.id == requested.id else { return }

        // If Neural Engine is disabled by user, use genuine online lyrics without AI transcription/alignment
        guard SettingsStore.shared.isNeuralEngineEnabled else {
            lyrics = result
            if let result, result.isSynchronized, !result.lines.isEmpty {
                cachedPhrases = LyricPhrase.from(lines: result.lines)
            }
            lyricsLoading = false
            return
        }

        // If no online lyrics found, attempt on-device Apple Neural Engine offline vocal transcription
        if result == nil || result?.lines.isEmpty == true {
            if let aiLyrics = await OnDeviceVocalAligner.shared.transcribe(track: requested) {
                result = aiLyrics
            }
        }

        guard !Task.isCancelled, player.currentTrack?.id == requested.id else { return }
        lyrics = result

        if let result {
            if result.isSynchronized, !result.lines.isEmpty {
                cachedPhrases = LyricPhrase.from(lines: result.lines)
            } else if !result.lines.isEmpty {
                // Background On-Device AI Alignment (Apple Neural Engine) for unsynchronized lyrics
                Task.detached(priority: .userInitiated) {
                    if let aligned = await OnDeviceVocalAligner.shared.align(lyrics: result, track: requested) {
                        await MainActor.run {
                            guard self.player.currentTrack?.id == requested.id else { return }
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                self.lyrics = aligned
                                self.cachedPhrases = LyricPhrase.from(lines: aligned.lines)
                            }
                        }
                    }
                }
            }
        }
        lyricsLoading = false
    }
    private func loadVideoShot() async {
        videoShotURL = nil
        videoShotTrackID = nil
        teardownVideoLooper()
        guard let track else { return }
        let requestedTrackID = track.id
        let id = PlayerCore.yandexTrackID(from: track)
        guard !id.isEmpty else { return }
        let url = await YandexMusicService.shared.getVideoShotUrl(for: id)
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
        UserDefaults.standard.set(isVideoShotEnabled, forKey: "aurora_videoshot_enabled")
        if isVideoShotEnabled, videoShotTrackID == track?.id, let videoShotURL {
            setupVideoLooper(url: videoShotURL)
        } else {
            teardownVideoLooper()
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
        guard let current = track else { return }; waveLoading = true
        waveActive = true
        Task {
            let tracks = await YandexMusicService.shared.buildTrackWave(from: current, target: 45)
            await MainActor.run {
                waveLoading = false
                let waveTracks = tracks.filter { $0.id != current.id }
                MoodRadioEngine.shared.startTrackWave(seed: current, initialTracks: waveTracks)
                waveMessage = "🌊 Моя волна по треку запущена"
            }
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run { waveMessage = nil }
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
    @State private var userScrolledUntil: Date = .distantPast

    private var isUserInteracting: Bool {
        Date() < userScrolledUntil
    }

    private var activeIndex: Int? {
        guard lyrics.isSynchronized, !lyrics.lines.isEmpty else { return nil }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let time = max(0, player.progress - latency + settings.lyricsOffset)
        if let first = lyrics.lines.first, time < first.startTime {
            return nil
        }
        for (i, line) in lyrics.lines.enumerated() {
            let nextStart = (i + 1 < lyrics.lines.count) ? lyrics.lines[i + 1].startTime : (line.startTime + 20.0)
            if time >= line.startTime && time < nextStart {
                return i
            }
        }
        return lyrics.lines.count - 1
    }

    var body: some View {
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
                                userScrolledUntil = .distantPast
                                if lyrics.isSynchronized {
                                    player.seek(to: max(0, line.startTime))
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
                        // Пользователь листает текст пальцем — ставим паузу на автоскролл
                        userScrolledUntil = Date().addingTimeInterval(4.5)
                    }
            )
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
                        userScrolledUntil = .distantPast
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
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex, !isUserInteracting else { return }
                withAnimation(.easeInOut(duration: 0.42)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                if let activeIndex {
                    proxy.scrollTo(activeIndex, anchor: .center)
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
        VStack(spacing: 8) {
            GeometryReader { geo in
                let duration = max(player.duration, 0.01)
                let fraction = min(1, max(0, effectiveProgress / duration))
                let width = geo.size.width * fraction
                let height: CGFloat = isScrubbing ? 11 : 6
                let cornerRadius: CGFloat = 3.0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white.opacity(0.18))
                        .frame(height: height)
                    if let bufferFraction = player.downloadProgress, bufferFraction > 0.005 {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.white.opacity(0.38))
                            .frame(width: max(height, geo.size.width * min(1.0, CGFloat(bufferFraction))), height: height)
                            .animation(.easeInOut(duration: 0.25), value: bufferFraction)
                    }
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.white)
                        .frame(width: max(height, width), height: height)
                    if isScrubbing {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(.white)
                            .frame(width: 12, height: 24)
                            .offset(x: max(0, min(width - 6, geo.size.width - 12)))
                            .shadow(color: .black.opacity(0.40), radius: 4, y: 1)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isScrubbing)
                .frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing { isScrubbing = true; feedback.prepare() }
                        let f = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                        scrubProgress = f * duration
                        if abs(f - lastFeedbackProgress) > 0.04 { Haptics.scrubTick(feedback); lastFeedbackProgress = f }
                    }
                    .onEnded { value in
                        let f = min(1, max(0, value.location.x / max(geo.size.width, 1)))
                        let target = f * duration
                        pendingSeekProgress = target
                        player.seek(to: target)
                        withAnimation(AG.spring) { isScrubbing = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            if pendingSeekProgress == target {
                                pendingSeekProgress = nil
                            }
                        }
                    })
            }.frame(height: 28)
            HStack {
                Text(player.formatted(effectiveProgress)).font(AG.text(.caption, .semibold).monospacedDigit()).foregroundStyle(AG.inkMuted)
                Spacer(); center; Spacer()
                Text("-" + player.formatted(max(0, player.duration - effectiveProgress))).font(AG.text(.caption, .semibold).monospacedDigit()).foregroundStyle(AG.inkMuted)
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

struct AutoMixBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title = "Mixing"
    private let sweepCycle: TimeInterval = 2.4

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
            .font(.system(size: 13, weight: .semibold, design: .default))

        return label
            .foregroundStyle(.white.opacity(0.85))
            .overlay {
                if let sweep {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let band = max(width * 0.55, 24)
                        let travel = width + band * 2

                        LinearGradient(
                            colors: [.clear, .white.opacity(0.40), .white, .white.opacity(0.40), .clear],
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
            .shadow(color: .white.opacity(0.40), radius: 6)
            .shadow(color: .white.opacity(0.15), radius: 12)
            .fixedSize()
            .compositingGroup()
    }
}

@MainActor
@Observable
final class SystemVolumeManager {
    static let shared = SystemVolumeManager()
    var volume: Float = 1.0
    private weak var systemSlider: UISlider?
    private var observation: NSKeyValueObservation?
    private var isSettingInternal = false

    private init() {
        let saved = PlayerCore.shared.volume
        volume = saved > 0 ? saved : AVAudioSession.sharedInstance().outputVolume
        let session = AVAudioSession.sharedInstance()
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newVol = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self = self, !self.isSettingInternal else { return }
                self.volume = newVol
                PlayerCore.shared.volume = newVol
            }
        }
    }

    func attach(slider: UISlider) {
        self.systemSlider = slider
    }

    func setVolume(_ newVolume: Float) {
        let clamped = max(0.0, min(1.0, newVolume))
        isSettingInternal = true
        self.volume = clamped
        PlayerCore.shared.volume = clamped
        systemSlider?.setValue(clamped, animated: false)
        systemSlider?.sendActions(for: .valueChanged)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isSettingInternal = false
        }
    }
}

final class SystemVolumeHostView: UIView {
    private let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 60, height: 20))

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
        volumeView.alpha = 0.001
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
        findSlider()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.findSlider()
        }
    }

    private func findSlider() {
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                SystemVolumeManager.shared.attach(slider: slider)
                return
            }
        }
    }
}

struct InvisibleVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> SystemVolumeHostView {
        SystemVolumeHostView(frame: CGRect(x: 0, y: 0, width: 60, height: 20))
    }

    func updateUIView(_ uiView: SystemVolumeHostView, context: Context) {}
}

struct FluidVolumeSlider: View {
    @State private var volumeManager = SystemVolumeManager.shared
    @State private var isDragging = false
    @State private var dragVolume: Float = 0.5

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AG.inkMuted)
                .frame(width: 16, height: 16, alignment: .center)

            GeometryReader { geo in
                let width = geo.size.width
                let currentVol = isDragging ? dragVolume : volumeManager.volume
                let progress = CGFloat(max(0.0, min(1.0, currentVol)))
                let filledWidth = max(6, width * progress)
                let trackHeight: CGFloat = isDragging ? 11 : 7
                let cornerRadius: CGFloat = 3.0
                let thumbWidth: CGFloat = isDragging ? 10 : 6
                let thumbHeight: CGFloat = isDragging ? 22 : 16

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(height: trackHeight)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white)
                        .frame(width: filledWidth, height: trackHeight)

                    RoundedRectangle(cornerRadius: isDragging ? 3.0 : 2.0, style: .continuous)
                        .fill(Color.white)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: max(0, min(filledWidth - (thumbWidth / 2), width - thumbWidth)))
                }
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
                            dragVolume = fraction
                            volumeManager.setVolume(fraction)
                        }
                        .onEnded { value in
                            let fraction = Float(max(0.0, min(1.0, value.location.x / max(width, 1))))
                            volumeManager.setVolume(fraction)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: 28)
            .background(InvisibleVolumeView().frame(width: 60, height: 20).opacity(0.001).allowsHitTesting(false))

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AG.inkMuted)
                .frame(width: 16, height: 16, alignment: .center)
        }
        .frame(height: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Громкость")
        .accessibilityValue("\(Int(volumeManager.volume * 100))%")
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
        .presentationDetents([.height(370), .medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var qualitySettingsList: some View {
        List {
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
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
            return "Аудио без потерь (Lossless) воспроизводится с оригинальным студийным качеством записи без потери деталей звука."
        }
        if bitrate >= 320 || codec.contains("mp3") || codec.contains("aac") {
            return "Аудио высокого качества воспроизводится с оптимизированным сжатием данных для быстрого и стабильного воспроизведения."
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

#Preview("Full player") { PlayerScreenV2(isPresented: .constant(true)) }
#Preview("Timeline") { PlayerTimelineSection(player: ActivePlayerPresentation()) { AutoMixBadge() }.padding() }
