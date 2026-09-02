import SwiftUI
import UIKit
import MediaPlayer

// MARK: - Sonivo Native Full Player (Apple Music iOS 26/27 Standard)

struct PlayerScreenV2: View {
    @State private var player = PlayerCore.shared
    @State private var library = LibraryStore.shared
    @State private var taste = UserTasteEngine.shared
    @Binding var isPresented: Bool

    init(isPresented: Binding<Bool>, dragOffsetY: Binding<CGFloat> = .constant(0)) {
        self._isPresented = isPresented
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // Native medium control metrics.
    private let tapSide: CGFloat = 44
    private let iconGlyph: CGFloat = 19
    private let skipGlyph: CGFloat = 30
    private let playGlyph: CGFloat = 40

    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var resolvingArtist = false

    // Unified Modal State Machine
    enum ActivePlayerModal: String, Identifiable {
        case queue, equalizer, sleepTimer, settings, quality, artistSelection
        var id: String { rawValue }
    }
    @State private var activeModal: ActivePlayerModal? = nil

    // Player Display Modes
    @State private var showLyricsMode = false
    @State private var dj = AutoMixDJEngine.shared

    // Track Wave state
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String? = nil

    // Lyrics state
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false

    // Cover swipe gesture offset
    @State private var coverDragX: CGFloat = 0

    // Colours extracted from the current artwork, driving the background
    @State private var artworkPaletteColors: [Color] = []
    @State private var paletteTrackId: UUID? = nil

    private var track: Track? { player.currentTrack }
    private var displayedMetadataTrack: Track? { player.displayTrack }

    private var palette: [Color] {
        if !artworkPaletteColors.isEmpty { return artworkPaletteColors }
        if let p = track?.palette, !p.isEmpty { return p }
        return Palette.seeded(42).colors
    }

    private func updatePalette(from image: UIImage) async {
        let hexes = await Task.detached(priority: .utility) {
            LibraryStore.artworkPalette(from: image)
        }.value
        let colors = hexes.compactMap { Color(hex: $0) }
        guard !colors.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.85)) {
            artworkPaletteColors = colors
        }
    }

    private func refreshPalette() async {
        guard let track else { return }
        guard paletteTrackId != track.id else { return }

        try? await Task.sleep(nanoseconds: 200_000_000)
        guard player.currentTrack?.id == track.id else { return }
        paletteTrackId = track.id

        if let image = LibraryStore.cachedArtworkImage(for: track) {
            await updatePalette(from: image)
            return
        }

        if let cover = track.coverURL, let url = URL(string: cover) {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = UIImage(data: data) {
                guard player.currentTrack?.id == track.id else { return }
                await updatePalette(from: image)
                return
            }
        }

        let fallback = track.palette
        guard !fallback.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.85)) {
            artworkPaletteColors = fallback
        }
    }

    var body: some View {
        GeometryReader { geo in
            let coverSide = min(geo.size.width - 64, geo.size.height * 0.40, 360)

            ZStack {
                // 1. Apple Music Ambient Liquid Mesh Background
                if reduceMotion || scenePhase != .active {
                    artworkGradientBackground
                    contrastProtectionVignette
                } else {
                    AnimatedMeshBackground(palette: backgroundColors)
                    contrastProtectionVignette
                }

                // 2. Main Player Container (Controls ALWAYS pinned on top)
                VStack(spacing: 0) {
                    // Top Bar (Grabber Pill & Dismiss Chevron)
                    topHeader
                        .padding(.top, 12)
                        .padding(.horizontal, 24)

                    Spacer(minLength: 8)

                    // Center Stage: Standard Square Artwork or Synced Lyrics
                    if showLyricsMode {
                        lyricsStage
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else {
                        artworkStage(side: coverSide)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                AutoMixTransitionOverlay(side: coverSide)
                            )
                            .transition(.opacity)
                    }

                    Spacer(minLength: 8)

                    // Floating status line: Track Wave toast only
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

                    // Lower Controls Section (Apple Music Standard Layout)
                    appleMusicLowerDeck
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: dj.isTransitionActive)
        .sheet(item: $activeModal) { modal in
            NavigationStack {
                switch modal {
                case .queue:
                    QueueModalView(isPresented: Binding(
                        get: { activeModal == .queue },
                        set: { if !$0 { activeModal = nil } }
                    ))
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
            await refreshPalette()
            await loadLyrics()
        }
    }

    // MARK: - Artwork Gradient Background

    private var backgroundColors: [Color] {
        let source = palette
        return source.isEmpty ? [AG.amber, AG.ember] : Array(source.prefix(3))
    }

    private var artworkGradientBackground: some View {
        let colors = backgroundColors
        let primary = colors[0]
        let secondary = colors.count > 1 ? colors[1] : primary
        let tertiary = colors.count > 2 ? colors[2] : secondary

        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: primary.opacity(0.62), location: 0.00),
                    .init(color: secondary.opacity(0.42), location: 0.36),
                    .init(color: tertiary.opacity(0.20), location: 0.66),
                    .init(color: .black.opacity(0.96), location: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [secondary.opacity(0.28), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 720
            )
        }
        .compositingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.70), value: colors)
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
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 42, height: 5)

            Spacer()

            Menu {
                Section("Плеер") {
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
                    .font(.system(size: iconGlyph, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Ещё")
        }
        .frame(minHeight: tapSide)
    }

    // MARK: - Center Stage: Standard Artwork

    private func artworkStage(side: CGFloat) -> some View {
        artwork
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(
                color: (artworkPaletteColors.first ?? Color.black).opacity(player.isPlaying ? 0.55 : 0.15),
                radius: player.isPlaying ? 32 : 10,
                x: 0,
                y: player.isPlaying ? 18 : 6
            )
            .scaleEffect(player.isPlaying ? 1.0 : 0.85)
            .offset(x: coverDragX)
            .rotationEffect(.degrees(Double(coverDragX / 24)), anchor: .center)
            .gesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { val in
                        guard abs(val.translation.width) > abs(val.translation.height) else { return }
                        let translation = val.translation.width
                        let damping: CGFloat = 1.0 + (abs(translation) * 0.003)
                        coverDragX = translation / damping
                    }
                    .onEnded { val in
                        guard abs(val.translation.width) > abs(val.translation.height) else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { coverDragX = 0 }
                            return
                        }
                        let threshold: CGFloat = 50
                        if val.translation.width < -threshold {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { coverDragX = -side * 1.2 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                nextTrack()
                                coverDragX = side * 1.2
                                withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) { coverDragX = 0 }
                            }
                        } else if val.translation.width > threshold {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { coverDragX = side * 1.2 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                previousTrack()
                                coverDragX = -side * 1.2
                                withAnimation(.spring(response: 0.40, dampingFraction: 0.78)) { coverDragX = 0 }
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { coverDragX = 0 }
                        }
                    }
            )
            .frame(width: side, height: side)
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
    }

    @ViewBuilder private var artwork: some View {
        if let track {
            ArtworkView(track: track)
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .overlay(Image(systemName: "music.note").font(.system(size: 48)).foregroundStyle(.white.opacity(0.35)))
        }
    }

    // MARK: - Lyrics Stage

    @ViewBuilder private var lyricsStage: some View {
        if lyricsLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                Text("Загрузка текста...")
                    .font(AG.text(14, .medium))
                    .foregroundStyle(.white.opacity(0.70))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics, !lyrics.lines.isEmpty {
            SyncedLyricsView(lyrics: lyrics, currentTime: player.progress) { seekTime in
                player.seek(to: seekTime)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Текст песни недоступен")
                    .font(AG.text(16, .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Для этого трека слова еще не добавлены")
                    .font(AG.text(13, .regular))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Lower Deck: Standard Apple Music Layout

    private var appleMusicLowerDeck: some View {
        VStack(spacing: 16) {
            // 1. Track Info (Title, Artist, Like button)
            trackMetadataRow

            // 2. Scrubber Timeline & Center Status Slot
            PlayerTimelineSection {
                centerStatusLabel
            }

            // 3. Playback Controls (Previous, Play/Pause, Next)
            transportControls

            // 4. Volume Slider (Native iOS)
            volumeBar

            // 5. Bottom Accessory Bar (Lyrics, AirPlay, Queue)
            appleMusicBottomBar
        }
    }

    // MARK: - Track Metadata Row

    private var trackMetadataRow: some View {
        let current = displayedMetadataTrack ?? track
        let isFav = current.map { taste.isFavorite($0) } ?? false

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(current?.title ?? "Не играет")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                    .contentTransition(.numericText())

                Button(action: openArtist) {
                    Text(current?.artist ?? "")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .buttonStyle(.plain)
                .disabled(current == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right accessories: Wave button & Favorite heart
            HStack(spacing: 12) {
                if let current, current.isStream {
                    Button(action: startTrackWave) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: iconGlyph, weight: .bold))
                            .foregroundStyle(waveActive ? AG.amber : .white.opacity(0.75))
                            .frame(width: tapSide, height: tapSide)
                            .contentShape(Circle())
                    }
                    .buttonStyle(GlassPressStyle())
                    .disabled(waveLoading)
                    .accessibilityLabel("Моя волна по треку")
                }

                Button {
                    guard let current else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    taste.toggleFavorite(current)
                } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .font(.system(size: iconGlyph + 2, weight: .bold))
                        .foregroundStyle(isFav ? Color.pink : Color.white.opacity(0.75))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: tapSide, height: tapSide)
                        .contentShape(Circle())
                }
                .buttonStyle(GlassPressStyle())
                .disabled(current == nil)
                .accessibilityLabel(isFav ? "Удалить из избранного" : "В избранное")
            }
        }
    }

    // MARK: - Center Status Slot (AutoMix mark or Quality badge)

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
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("flac") {
            return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"
        }
        if bitrate >= 320 {
            return "HQ \(bitrate) kbps"
        }
        if bitrate > 0 {
            return "\(bitrate) kbps"
        }
        return player.audioQuality.badgeText
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: skipGlyph, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.88))
            .accessibilityLabel("Предыдущий трек")

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playGlyph, weight: .black))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.82))
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")

            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: skipGlyph, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.88))
            .accessibilityLabel("Следующий трек")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Volume Slider

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

    // MARK: - Bottom Bar (Lyrics, AirPlay, Queue)

    private var appleMusicBottomBar: some View {
        HStack(alignment: .center) {
            Button {
                withAnimation(AG.spring) {
                    showLyricsMode.toggle()
                }
            } label: {
                Image(systemName: showLyricsMode ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: iconGlyph, weight: .semibold))
                    .foregroundStyle(showLyricsMode ? AG.amber : .white.opacity(0.65))
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassPressStyle())
            .accessibilityLabel("Текст песни")

            Spacer()

            AirPlayButtonView()
                .frame(width: tapSide, height: tapSide)
                .contentShape(Rectangle())
                .accessibilityLabel("AirPlay")

            Spacer()

            Button {
                openModal(.queue)
            } label: {
                Image(systemName: activeModal == .queue ? "list.bullet.rectangle.portrait.fill" : "list.bullet")
                    .font(.system(size: iconGlyph, weight: .semibold))
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

    // MARK: - Modal Contents

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isPresented = false
    }
}

// MARK: - Timeline Section (scrubber, timings and center status slot)

struct PlayerTimelineSection<Center: View>: View {
    @State private var player = PlayerCore.shared
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var lastFeedbackProgress: Double = 0.0

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let center: Center

    init(@ViewBuilder center: () -> Center) {
        self.center = center()
    }

    private var effectiveProgress: Double {
        isScrubbing ? scrubProgress : player.progress
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let maxDuration = max(player.duration, 0.01)
                let currentFraction = min(1.0, max(0.0, effectiveProgress / maxDuration))
                let activeWidth = max(0, min(geo.size.width, geo.size.width * currentFraction))
                let barHeight: CGFloat = isScrubbing ? 10 : 4

                ZStack(alignment: .leading) {
                    // Track background line
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(height: barHeight)

                    // Filled progress line
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(barHeight, activeWidth), height: barHeight)

                    // Thumb knob
                    if isScrubbing {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                            .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
                            .offset(x: activeWidth - 11)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            if !isScrubbing {
                                isScrubbing = true
                                selectionFeedback.prepare()
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                            let fraction = min(1.0, max(0.0, val.location.x / geo.size.width))
                            scrubProgress = fraction * maxDuration

                            if abs(fraction - lastFeedbackProgress) > 0.04 {
                                selectionFeedback.selectionChanged()
                                lastFeedbackProgress = fraction
                            }
                        }
                        .onEnded { val in
                            let fraction = min(1.0, max(0.0, val.location.x / geo.size.width))
                            let target = fraction * maxDuration
                            player.seek(to: target)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                isScrubbing = false
                            }
                        }
                )
            }
            .frame(height: 24)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isScrubbing)

            // Timings and center status line
            HStack(alignment: .center) {
                Text(player.formatted(effectiveProgress))
                    .font(AG.text(12, .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(isScrubbing ? 1.0 : 0.60))

                Spacer()

                center

                Spacer()

                Text("-" + player.formatted(max(0, player.duration - effectiveProgress)))
                    .font(AG.text(12, .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(isScrubbing ? 1.0 : 0.60))
            }
            .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        }
    }
}

// MARK: - AutoMix mark (Apple Music "Mixing" style)

struct AutoMixBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let title = "AutoMix"
    private let sweepCycle: TimeInterval = 2.6

    var body: some View {
        Group {
            if reduceMotion {
                fullMark(sweep: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let phase = time.truncatingRemainder(dividingBy: sweepCycle) / sweepCycle
                    fullMark(sweep: CGFloat(phase))
                }
            }
        }
        .accessibilityLabel(Text(title))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func fullMark(sweep: CGFloat?) -> some View {
        let usingGemini = GeminiAutoMixPlanner.lastPlanUsedGemini
        HStack(spacing: 4) {
            mark(sweep: sweep)
            Text(usingGemini ? "AI" : "DSP")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(usingGemini ? Color.green.opacity(0.85) : Color.white.opacity(0.45))
                .fixedSize()
                .accessibilityLabel(Text(usingGemini ? "План Gemini AI" : "Локальный DSP-движок"))
        }
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
