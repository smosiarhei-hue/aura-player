// Path: Sonivo/MyWaveHeroView.swift
// Премиальная нативная витрина «Моя волна» (Apple Design & Emil Kowalski Design Engineering)
// Чистая пространственная сцена, нативное размытие без лишних рамок, кругов и квадратов.

import SwiftUI

struct MyWaveHeroView: View {
    var player: ActivePlayerPresentation
    @Binding var showPlayer: Bool
    @Binding var showSettings: Bool
    var showAIAssistant: Binding<Bool>? = nil
    var onToggleWave: () -> Void
    var onShakeWave: (() -> Void)? = nil

    @State private var waveStore = WaveSettingsStore.shared
    @State private var library = LibraryStore.shared
    @State private var artistImageUrl: String? = nil
    @State private var artistLookupTrackId: UUID? = nil
    @State private var isFilterExpanded: Bool = false

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

            // 2. Central Stage: Чистая обложка с нативным пространственным размытием (без рамок и линий)
            centralVisualStage
                .frame(height: 270)
                .contentShape(Rectangle())
                .gesture(swipeGesture)
                .padding(.top, 10)

            // 3. Pending 2-Second Grace Period Banner (if swiped)
            if pendingTrack != nil {
                pendingGraceBanner
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 4. Название трека и артист (стандартно, чисто)
            trackMetadataSection
                .padding(.top, 14)

            // 5. Стандартная нативная панель управления (Apple Music Style)
            standardControlsRow
                .padding(.top, 14)

            // 6. Настроение и язык (аккуратные капсулы без жестких рамок)
            bottomSparklesAndChips
                .padding(.top, 18)
        }
        .padding(.vertical, 12)
        .task(id: activeTrack?.id) {
            await resolveArtistPhoto()
        }
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Text("Моя волна")
                    .font(SN.display(.title, .black))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)
                    .accessibilityIdentifier("sonivo.my-wave.title")

                if player.isPlaying {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: accentColor.opacity(0.8), radius: 4)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if let showAIAssistant {
                    Button {
                        Haptics.tap(.light)
                        showAIAssistant.wrappedValue = true
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: SN.tapTarget, height: SN.tapTarget)
                            .background(.ultraThinMaterial.opacity(0.70), in: Circle())
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.92))
                    .accessibilityLabel("AI-куратор")
                    .accessibilityHint("Открывает музыкального помощника")
                }

                Button {
                    Haptics.tap(.light)
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: SN.tapTarget, height: SN.tapTarget)
                        .background(.ultraThinMaterial.opacity(0.70), in: Circle())
                }
                .buttonStyle(TactileButtonStyle(scale: 0.92))
                .accessibilityLabel("Настройки")
                .accessibilityHint("Открывает оформление, звук и параметры приложения")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Central Living Spatial Stage (Apple Spatial Blur - No Lines, No Frames)
    private var centralVisualStage: some View {
        ZStack {
            // Главная нативная суперэллиптическая карточка обложки 220x220 (чистый Apple Design)
            Button {
                Haptics.tap(.light)
                showPlayer = true
            } label: {
                ZStack {
                    if let cover = activeTrack?.coverURL {
                        RemoteArtwork(urlString: cover, corner: 26)
                            .frame(width: 220, height: 220)
                    } else if let track = activeTrack {
                        SmallArtwork(track: track, size: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color(white: 0.15))
                            .frame(width: 220, height: 220)
                            .overlay(
                                Image(systemName: "waveform")
                                    .font(.system(size: 48, weight: .bold))
                                    .foregroundStyle(accentColor)
                            )
                    }
                }
                .shadow(color: Color.black.opacity(0.60), radius: 26, y: 12)
                .shadow(color: accentColor.opacity(0.35), radius: 20, y: 6)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.97))
            .accessibilityLabel("Открыть плеер")
        }
        .offset(x: dragOffset)
        .rotationEffect(.degrees(Double(dragOffset / 200.0) * 3.5))
        .scaleEffect(1.0 - min(0.04, abs(dragOffset / 300.0) * 0.04))
    }

    // MARK: - Track Metadata Section (Standard, Clean, Apple Style)
    private var trackMetadataSection: some View {
        Button {
            Haptics.tap(.light)
            if pendingTrack != nil {
                commitPendingSkipNow()
            }
            showPlayer = true
        } label: {
            VStack(spacing: 3) {
                Text(activeTrack?.title ?? "Включить волну")
                    .font(.system(size: 20, weight: .bold, design: .default))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(activeTrack?.artist ?? "Персональный музыкальный поток")
                    .font(.system(size: 15, weight: .medium, design: .default))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Standard Native Controls Row (Apple Music Transport)
    private var standardControlsRow: some View {
        HStack(spacing: 28) {
            // Кнопка «Назад»
            Button {
                Haptics.tap(.light)
                if pendingTrack != nil {
                    commitPendingSkipNow()
                }
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))
            .accessibilityLabel("Предыдущий трек")

            // Главная Hero-кнопка Play / Pause
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
                        .fill(accentColor)
                        .frame(width: 64, height: 64)
                        .shadow(color: accentColor.opacity(0.50), radius: 16, y: 4)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Color.black)
                }
            }
            .buttonStyle(TactileButtonStyle(scale: 0.93))
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизведение")

            // Кнопка «Вперед»
            Button {
                Haptics.tap(.light)
                if pendingTrack != nil {
                    commitPendingSkipNow()
                }
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.90))
            .accessibilityLabel("Следующий трек")
        }
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
        .background(.ultraThinMaterial.opacity(0.90), in: Capsule())
        .padding(.horizontal, 24)
    }

    // MARK: - Bottom Wave Tuning Chips (Чистые капсулы без жестких рамок)
    private var bottomSparklesAndChips: some View {
        VStack(spacing: 8) {
            // Компактная нативная плашка-фильтр «Моей волны»
            Button {
                Haptics.tap(.light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    isFilterExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: waveStore.diversity.icon)
                        .font(.system(size: 11, weight: .bold))
                    Text("\(waveStore.diversity.title) • \(waveStore.language.title)")
                        .font(SN.text(.footnote, .semibold))
                    Image(systemName: isFilterExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial.opacity(0.40), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(TactileButtonStyle(scale: 0.96))

            if isFilterExpanded {
                VStack(spacing: 10) {
                    // 1. Музыкальный характер (diversity)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(WaveDiversity.allCases.enumerated()), id: \.element.id) { _, item in
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
                                        isSelected ? Color.white : Color.white.opacity(0.10),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    // 2. Язык звучания
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(Array(WaveLanguage.allCases.enumerated()), id: \.element.id) { _, item in
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
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
                    initiateGracefulSkip(direction: 1)
                } else if value.translation.width > threshold || projected > 90 {
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
