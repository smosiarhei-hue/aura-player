import SwiftUI

struct MyWaveHeroView: View {
    var player: ActivePlayerPresentation
    @Binding var showPlayer: Bool
    @Binding var showSettings: Bool
    @Binding var showWaveSettings: Bool
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
        return AG.accent
    }

    private var isFavorite: Bool {
        guard let t = activeTrack else { return false }
        return library.isTrackFavorite(t)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header: Centered "Моя волна" + Top Right Search
            headerBar

            // 2. Bold Vibrant Artist Name(s)
            artistTitleSection
                .padding(.top, 8)
                .padding(.bottom, 12)

            // 3. Central Stage: Artist Cutout + Overlaid Track Artwork Sleeve
            centralVisualStage
                .frame(height: 290)
                .scaleEffect(isWaveShaking ? 1.07 : 1.0)
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
            // Native iOS 26/27 Liquid Aura Glow (No heavy video loop!)
            atmosphericAuraBackdrop
        }
        .task(id: activeTrack?.id) {
            await resolveArtistPhoto()
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            // Left spacer or settings shortcut
            Button {
                showSettings = true
            } label: {
                if let avatar = YandexMusicService.shared.currentUser?.avatarUrl {
                    RemoteArtwork(urlString: avatar, corner: 14)
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Профиль")

            Spacer()

            // Centered "Моя волна" title
            Text("Моя волна")
                .font(.system(size: 20, weight: .heavy, design: .default))
                .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16))
                .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)

            Spacer()

            // Right: Search Button
            NavigationLink {
                SearchCatalogView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Поиск")
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Artist Title Section
    private var artistTitleSection: some View {
        VStack(spacing: 4) {
            if let artist = activeTrack?.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 28, weight: .black, design: .default))
                    .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16))
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

    // MARK: - Central Visual Stage
    private var centralVisualStage: some View {
        ZStack {
            // Soft atmospheric glow behind the artwork
            RadialGradient(
                colors: [
                    accentColor.opacity(0.35),
                    Color(red: 0.15, green: 0.25, blue: 0.50).opacity(0.20),
                    Color.clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 180
            )
            .blur(radius: 40)

            // Behind: Artist cutout/photo if available
            if let artistImageUrl {
                RemoteArtwork(urlString: artistImageUrl, corner: 999)
                    .frame(width: 210, height: 210)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1.5))
                    .shadow(color: Color.black.opacity(0.60), radius: 24, y: 8)
                    .offset(y: -24)
            } else {
                // Subtle glowing silhouette aura when no separate photo
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(0.25), Color.blue.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 190, height: 190)
                    .blur(radius: 20)
                    .offset(y: -20)
            }

            // In Front: The square track cover sleeve pinned over the lower half
            if let cover = activeTrack?.coverURL {
                RemoteArtwork(urlString: cover, corner: 18)
                    .frame(width: 146, height: 146)
                    .shadow(color: Color.black.opacity(0.85), radius: 18, y: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.2)
                    )
                    .offset(y: artistImageUrl != nil ? 34 : 0)
            } else if let track = activeTrack {
                SmallArtwork(track: track, size: 146)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color.black.opacity(0.85), radius: 18, y: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.2)
                    )
                    .offset(y: artistImageUrl != nil ? 34 : 0)
            }
        }
        .offset(x: dragOffset)
    }

    // MARK: - 2-Second Pending Grace Period Banner
    private var pendingGraceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16))

            Text("Переключение через \(String(format: "%.1f", pendingCountdown))с")
                .font(AG.text(.caption, .bold))
                .foregroundStyle(.white)

            Spacer()

            Button {
                cancelPendingSkip()
            } label: {
                Text("Отмена")
                    .font(AG.text(.caption2, .heavy))
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
                    .font(AG.text(.caption2, .heavy))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.98, green: 0.88, blue: 0.16), in: Capsule())
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
            // Left: Play/Pause Circular Capsule
            Button {
                Haptics.tap(.medium)
                if pendingTrack != nil {
                    commitPendingSkipNow()
                } else {
                    onToggleWave()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.14).opacity(0.92))
                        .frame(width: 60, height: 60)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16))
                }
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизведение")

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
                        .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .scaleEffect(antigravity.phase == .antigravity ? antigravity.typographyExitScale : (antigravity.phase == .settling ? antigravity.typographyEnterScale : 1.0))
                        .opacity(antigravity.phase == .antigravity ? antigravity.typographyExitOpacity : (antigravity.phase == .settling ? antigravity.typographyEnterOpacity : 1.0))

                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16).opacity(0.9))
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color(white: 0.14).opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.95))
            .accessibilityLabel("Открыть плеер")

            // Right: Favorite Heart Circular Capsule
            Button {
                Haptics.tap(.light)
                if let t = activeTrack {
                    library.toggleFavorite(t)
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(white: 0.14).opacity(0.92))
                        .frame(width: 60, height: 60)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)

                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.88, blue: 0.16))
                }
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .accessibilityLabel(isFavorite ? "Удалить из избранного" : "В избранное")
        }
    }

    // MARK: - Bottom Sparkles & Wave Tuning Chips
    private var bottomSparklesAndChips: some View {
        VStack(spacing: 12) {
            // Кнопка «Встряхнуть волну» (или деликатные искры)
            Button {
                Haptics.tap(.medium)
                antigravity.triggerShift()
                onShakeWave?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.0, green: 0.95, blue: 0.99))
                    Text("Встряхнуть волну")
                        .font(AG.text(.caption2, .bold))
                        .foregroundStyle(.white.opacity(0.90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.94))
            .accessibilityLabel("Встряхнуть мою волну")

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
                                    .font(AG.text(.footnote, .semibold))
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

            // 2. Язык звучания + Настройки волны
            HStack(spacing: 8) {
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
                                        .font(AG.text(.caption, .semibold))
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
                    .padding(.leading, 20)
                }

                Button {
                    showWaveSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .glassCircle()
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
                        : .easeInOut(duration: 0.40).delay(0.28),
                    value: antigravity.isCardsFlipped
                )
                .padding(.trailing, 20)
                .accessibilityLabel("Все настройки волны")
            }
        }
    }

    // MARK: - Native iOS 26/27 Atmospheric Backdrop
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

    // MARK: - Swipe Gesture Handling with 2s Debounce
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width / (1 + abs(value.translation.width) * 0.001)
            }
            .onEnded { value in
                let threshold: CGFloat = 55
                if value.translation.width < -threshold {
                    // Swiped Left -> Request Next Track with 2s buffer
                    initiateGracefulSkip(direction: 1)
                } else if value.translation.width > threshold {
                    // Swiped Right -> Request Prev Track with 2s buffer
                    initiateGracefulSkip(direction: -1)
                }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
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
