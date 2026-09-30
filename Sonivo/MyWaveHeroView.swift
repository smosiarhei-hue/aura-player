// Path: Sonivo/MyWaveHeroView.swift
// Премиальная витрина «Моя волна» (Apple Design & Skiper UI Fluid Harmonics)
// Живая органическая сцена Aura Wave Stage, концентрические дыхающие ореолы и тактильные контролы.

import SwiftUI

struct MyWaveHeroView: View {
    var player: ActivePlayerPresentation
    @Binding var showPlayer: Bool
    @Binding var showSettings: Bool
    @Binding var showWaveSettings: Bool
    var showAIAssistant: Binding<Bool>? = nil
    var onToggleWave: () -> Void
    var onShakeWave: (() -> Void)? = nil
    var isWaveShaking: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var antigravity = AntigravityTransitionManager.shared
    @State private var waveStore = WaveSettingsStore.shared
    @State private var library = LibraryStore.shared
    @State private var artistImageUrl: String? = nil
    @State private var artistLookupTrackId: UUID? = nil

    // MARK: - 2-Second Swipe Grace Period / Debounce State
    @State private var dragOffset: CGFloat = 0
    @State private var pendingTrack: Track? = nil
    @State private var pendingDirection: Int = 0 // +1 for next, -1 for prev
    @State private var pendingCountdown: Double = 0 // 2.0 down to 0
    @State private var pendingTask: Task<Void, Never>? = nil

    private var activeTrack: Track? {
        pendingTrack ?? player.displayTrack
    }

    private var accentColor: Color {
        if let first = activeTrack?.palette.first {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(first).getRed(&r, green: &g, blue: &b, alpha: &a)
            if !(r > 0.68 && g > 0.58 && b < 0.42) {
                return first
            }
        }
        return SN.accent
    }

    private var isFavorite: Bool {
        guard let t = activeTrack else { return false }
        return library.isTrackFavorite(t)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header: "Моя волна" + Настройки
            headerBar

            // 2. Bold Artist Name(s)
            artistTitleSection
                .padding(.top, 8)
                .padding(.bottom, 14)

            // 3. Central Stage: Живая органическая сцена Aura Wave Stage (Skiper UI + Apple Design)
            centralVisualStage
                .frame(height: 290)
                .scaleEffect(isWaveShaking ? 1.08 : 1.0)
                .animation(.spring(response: 0.38, dampingFraction: 0.65), value: isWaveShaking)
                .contentShape(Rectangle())
                .gesture(swipeGesture)

            // 4. Pending 2-Second Grace Period Banner (if swiped)
            if pendingTrack != nil {
                pendingGraceBanner
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 5. Floating Dark Glass Capsule Controls Row
            capsuleControlsRow
                .padding(.top, pendingTrack != nil ? 10 : 16)
                .padding(.horizontal, 20)

            // 6. Sparkles Icon & Mood Diversity Pills
            bottomSparklesAndChips
                .padding(.top, 14)
        }
        .padding(.vertical, 12)
        .background {
            // Native iOS Liquid Aura Glow
            atmosphericAuraBackdrop
        }
        .task(id: activeTrack?.id) {
            await resolveArtistPhoto()
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Моя волна")
                    .font(.system(size: 26, weight: .black, design: .default))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)

                if player.isPlaying {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: accentColor.opacity(0.8), radius: 4)
                }
            }

            Spacer()

            Button {
                Haptics.tap(.light)
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 42, height: 42)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .accessibilityLabel("Настройки")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .background {
            // Programmatic AI Assistant binding retention
            if let showAIAssistant = showAIAssistant, false {
                Image(systemName: "sparkles")
                    .onTapGesture { showAIAssistant.wrappedValue = true }
            }
        }
    }

    // MARK: - Artist Title Section
    private var artistTitleSection: some View {
        VStack(spacing: 4) {
            if let artist = activeTrack?.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 28, weight: .black, design: .default))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 24)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                    .scaleEffect(antigravity.phase == .antigravity ? antigravity.typographyExitScale : (antigravity.phase == .settling ? antigravity.typographyEnterScale : 1.0))
                    .opacity(antigravity.phase == .antigravity ? antigravity.typographyExitOpacity : (antigravity.phase == .settling ? antigravity.typographyEnterOpacity : 1.0))
            }
        }
    }

    // MARK: - Central Living Spatial Aura Stage (Apple Spatial Blur & Apple Design)
    private var centralVisualStage: some View {
        ZStack {
            // 1. Внешнее глубокое пространственное рассеяние (Deep Spatial Atmosphere Blur)
            Group {
                if let cover = activeTrack?.coverURL {
                    RemoteArtwork(urlString: cover, corner: 60)
                } else if let track = activeTrack {
                    SmallArtwork(track: track, size: 310)
                } else {
                    Circle().fill(accentColor)
                }
            }
            .frame(width: 310, height: 310)
            .blur(radius: 60)
            .saturation(1.4)
            .opacity(player.isPlaying ? 0.65 : 0.40)
            .scaleEffect(isWaveShaking ? 1.25 : (player.isPlaying ? 1.06 : 1.0))
            .animation(.spring(response: 0.60, dampingFraction: 0.8), value: isWaveShaking)
            .animation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true), value: player.isPlaying)

            // 2. Фокусированный ореол пространственной глубины (Mid Spatial Halo Blur)
            Group {
                if let artistImageUrl {
                    RemoteArtwork(urlString: artistImageUrl, corner: 999)
                } else if let cover = activeTrack?.coverURL {
                    RemoteArtwork(urlString: cover, corner: 40)
                } else if let track = activeTrack {
                    SmallArtwork(track: track, size: 245)
                } else {
                    Circle().fill(accentColor)
                }
            }
            .frame(width: 245, height: 245)
            .clipShape(Circle())
            .blur(radius: 28)
            .opacity(player.isPlaying ? 0.70 : 0.45)
            .scaleEffect(isWaveShaking ? 1.15 : (player.isPlaying ? 1.03 : 1.0))
            .animation(.spring(response: 0.50, dampingFraction: 0.8), value: isWaveShaking)
            .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: player.isPlaying)

            // 3. Главная суперэллиптическая карточка обложки (Hero Superellipse Card 210x210 - No Lines, Pure Spatial Apple Design)
            Button {
                Haptics.tap(.light)
                showPlayer = true
            } label: {
                ZStack {
                    if let cover = activeTrack?.coverURL {
                        RemoteArtwork(urlString: cover, corner: 28)
                            .frame(width: 210, height: 210)
                    } else if let track = activeTrack {
                        SmallArtwork(track: track, size: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color(white: 0.15))
                            .frame(width: 210, height: 210)
                            .overlay(
                                Image(systemName: "waveform")
                                    .font(.system(size: 48, weight: .bold))
                                    .foregroundStyle(accentColor)
                            )
                    }
                }
                .shadow(color: Color.black.opacity(0.65), radius: 28, y: 12)
                .shadow(color: accentColor.opacity(0.40), radius: 22, y: 6)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.97))
            .accessibilityLabel("Открыть плеер")
        }
        .offset(x: dragOffset)
        .rotationEffect(.degrees(Double(dragOffset / 200.0) * 3.5))
        .scaleEffect(1.0 - min(0.04, abs(dragOffset / 300.0) * 0.04))
    }

    // MARK: - 2-Second Pending Grace Period Banner
    private var pendingGraceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accentColor)

            Text("Переключение через \(String(format: "%.1f", pendingCountdown))с")
                .font(SN.text(.caption, .bold))
                .foregroundStyle(.white)

            Spacer()

            Button {
                cancelPendingSkip()
            } label: {
                Text("Отмена")
                    .font(SN.text(.caption2, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                commitPendingSkipNow()
            } label: {
                Text("Включить")
                    .font(SN.text(.caption2, .heavy))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(white: 0.15).opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.8))
        .padding(.horizontal, 24)
    }

    // MARK: - Floating Dark Glass Capsule Controls Row
    private var capsuleControlsRow: some View {
        HStack(spacing: 14) {
            // Left: "Включить мою волну"
            Button {
                Haptics.tap(.medium)
                if pendingTrack != nil {
                    commitPendingSkipNow()
                }
                onToggleWave()
                showPlayer = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.14).opacity(0.92))
                        .frame(width: 60, height: 60)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)

                    Image(systemName: "waveform")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accentColor)
                        .scaleEffect(player.isPlaying ? 1.06 : 1.0)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: player.isPlaying)
                }
            }
            .buttonStyle(TactileButtonStyle(scale: 0.95))
            .accessibilityLabel("Включить мою волну")

            // Center: Track Title & Info Pill (Tapping opens Full Player)
            Button {
                Haptics.tap(.light)
                if pendingTrack != nil {
                    commitPendingSkipNow()
                }
                showPlayer = true
            } label: {
                HStack(spacing: 8) {
                    Text(activeTrack?.title ?? "Включить волну")
                        .font(.system(size: 16, weight: .heavy, design: .default))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .scaleEffect(antigravity.phase == .antigravity ? antigravity.typographyExitScale : (antigravity.phase == .settling ? antigravity.typographyEnterScale : 1.0))
                        .opacity(antigravity.phase == .antigravity ? antigravity.typographyExitOpacity : (antigravity.phase == .settling ? antigravity.typographyEnterOpacity : 1.0))

                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accentColor.opacity(0.9))
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color(white: 0.14).opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.96))
            .accessibilityLabel("Открыть плеер")

            // Right: Play/Pause Circular Capsule
            Button {
                Haptics.tap(.medium)
                if pendingTrack != nil {
                    commitPendingSkipNow()
                }
                if player.isPlaying {
                    player.pause()
                } else {
                    if player.displayTrack != nil {
                        player.resume()
                    } else {
                        onToggleWave()
                    }
                    showPlayer = true
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.14).opacity(0.92))
                        .frame(width: 60, height: 60)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(accentColor)
                }
            }
            .buttonStyle(TactileButtonStyle(scale: 0.95))
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизведение")
        }
    }

    // MARK: - Bottom Wave Tuning Chips
    private var bottomSparklesAndChips: some View {
        VStack(spacing: 12) {
            // 1. Музыкальный характер (diversity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(WaveDiversity.allCases.enumerated()), id: \.element.id) { index, item in
                        let isSelected = waveStore.diversity == item
                        Button {
                            Haptics.tap(.light)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                waveStore.diversity = item
                            }
                            if player.isPlaying {
                                Task { _ = await waveStore.reseedActiveWaveQueue() }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 11, weight: .bold))
                                Text(item.title)
                                    .font(SN.text(.footnote, .semibold))
                            }
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.white : Color.white.opacity(0.12),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.18), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .offset(y: reduceMotion ? 0 : (antigravity.isCardsFlipped ? antigravity.cardsYOffset : 0))
                        .rotation3DEffect(
                            .degrees(reduceMotion ? 0 : (antigravity.isCardsFlipped ? 180 : 0)),
                            axis: (x: 1, y: 0, z: 0)
                        )
                        .opacity(reduceMotion && antigravity.phase != .idle ? 0.35 : 1.0)
                        .animation(
                            reduceMotion
                                ? .easeInOut(duration: 0.30)
                                : .easeInOut(duration: 0.40).delay(Double(index) * 0.040),
                            value: antigravity.isCardsFlipped
                        )
                    }
                }
                .padding(.horizontal, 20)
            }

            // 2. Язык звучания
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(WaveLanguage.allCases.enumerated()), id: \.element.id) { index, item in
                        let isSelected = waveStore.language == item
                        Button {
                            Haptics.tap(.light)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                waveStore.language = item
                            }
                            if player.isPlaying {
                                Task { _ = await waveStore.reseedActiveWaveQueue() }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 11, weight: .bold))
                                Text(item.title)
                                    .font(SN.text(.caption, .semibold))
                            }
                            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? Color.white : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.14), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .offset(y: reduceMotion ? 0 : (antigravity.isCardsFlipped ? antigravity.cardsYOffset : 0))
                        .rotation3DEffect(
                            .degrees(reduceMotion ? 0 : (antigravity.isCardsFlipped ? 180 : 0)),
                            axis: (x: 1, y: 0, z: 0)
                        )
                        .opacity(reduceMotion && antigravity.phase != .idle ? 0.35 : 1.0)
                        .animation(
                            reduceMotion
                                ? .easeInOut(duration: 0.30)
                                : .easeInOut(duration: 0.40).delay(Double(index + 3) * 0.040),
                            value: antigravity.isCardsFlipped
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Native iOS Atmospheric Backdrop
    private var atmosphericAuraBackdrop: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Deep fluid radial aura glows tailored to the track
            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.22, blue: 0.45).opacity(0.40),
                    accentColor.opacity(0.18),
                    Color.black
                ],
                center: .center,
                startRadius: 40,
                endRadius: 450
            )
            .blur(radius: 65)

            // Кинетический вихрь «Антигравити» (Metal Shader)
            if antigravity.distortionStrength > 0.01 {
                GeometryReader { geo in
                    Rectangle()
                        .colorEffect(
                            ShaderLibrary.antigravityVortex(
                                .float4(0, 0, Float(geo.size.width), Float(geo.size.height)),
                                .float(antigravity.distortionStrength),
                                .float(antigravity.vortexAngle),
                                .float(antigravity.colorShift),
                                .color(accentColor)
                            )
                        )
                        .ignoresSafeArea()
                        .opacity(Double(min(1.0, antigravity.distortionStrength * 2.0)))
                }
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0.0),
                    .init(color: .clear, location: 0.2),
                    .init(color: .clear, location: 0.8),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Swipe Gesture Handling with Velocity & Momentum
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let threshold: CGFloat = 50
                let projected = value.predictedEndTranslation.width
                if value.translation.width < -threshold || projected < -90 {
                    // Swiped Left -> Request Next Track with 2s buffer
                    initiateGracefulSkip(direction: 1)
                } else if value.translation.width > threshold || projected > 90 {
                    // Swiped Right -> Request Prev Track with 2s buffer
                    initiateGracefulSkip(direction: -1)
                }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    dragOffset = 0
                }
            }
    }

    private func initiateGracefulSkip(direction: Int) {
        pendingTask?.cancel()
        Haptics.tap(.light)

        // Find upcoming track in queue
        let queue = player.queue
        guard let current = player.displayTrack,
              let currentIndex = queue.firstIndex(where: { $0.id == current.id }) else {
            return
        }

        let targetIndex = direction > 0 ? (currentIndex + 1) : (currentIndex - 1)
        guard targetIndex >= 0 && targetIndex < queue.count else { return }

        let candidate = queue[targetIndex]
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingTrack = candidate
            pendingDirection = direction
            pendingCountdown = 2.0
        }

        // Start 2.0-second grace timer
        pendingTask = Task {
            for step in 1...20 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                await MainActor.run {
                    pendingCountdown = max(0, 2.0 - Double(step) * 0.10)
                }
            }

            if !Task.isCancelled {
                await MainActor.run {
                    commitPendingSkipNow()
                }
            }
        }
    }

    private func cancelPendingSkip() {
        pendingTask?.cancel()
        pendingTask = nil
        Haptics.tap(.light)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingTrack = nil
            pendingCountdown = 0
        }
    }

    private func commitPendingSkipNow() {
        pendingTask?.cancel()
        pendingTask = nil
        Haptics.tap(.medium)
        if pendingDirection > 0 {
            player.next()
        } else if pendingDirection < 0 {
            player.previous()
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingTrack = nil
            pendingCountdown = 0
        }
    }

    // MARK: - Artist Photo Resolution
    private func resolveArtistPhoto() async {
        guard let track = activeTrack, track.id != artistLookupTrackId else { return }
        artistLookupTrackId = track.id

        let artists = await YandexMusicService.shared.resolvePlayerArtists(for: track)
        if let first = artists.first, let item = try? await YandexMusicService.shared.getArtist(artistId: first.id) {
            await MainActor.run {
                if let cover = item.coverUrlString, !cover.isEmpty {
                    self.artistImageUrl = cover
                } else {
                    self.artistImageUrl = nil
                }
            }
        } else {
            await MainActor.run {
                self.artistImageUrl = nil
            }
        }
    }
}
