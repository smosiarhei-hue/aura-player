import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Sonivo Ember Fullscreen Player
// Полностью пересобранная раскладка: весь контент жёстко вписан в размер экрана,
// фон больше не раздувает компоновку, поэтому кнопки и ползунки нигде не обрезаются.

struct PlayerScreen: View {
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared
    @State private var library = LibraryStore.shared
    @Binding var isPresented: Bool
    let namespace: Namespace.ID

    @State private var scrubValue: Double? = nil
    @State private var isDraggingScrubber = false
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var showSettings = false
    @State private var showSleepTimer = false
    @State private var dragOffset: CGFloat = 0
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var lyrics: Lyrics?
    @State private var currentLyricLine: String?

    private var currentTrack: Track? { player.currentTrack }

    private var palette: [Color] { currentTrack?.palette ?? Palette.seeded(42).colors }

    private var qualityLabel: String {
        if let br = player.currentBitrate { return String(br) + " kbps" }
        return player.audioQuality.label
    }

    private var sleepTimerLabel: String {
        guard let remaining = player.sleepTimerRemaining else { return "Таймер сна" }
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "Таймер сна · %d:%02d", m, s)
    }

    private var sleepTimerShortLabel: String {
        guard let remaining = player.sleepTimerRemaining else { return "" }
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Body

    var body: some View {
        ZStack {
            backdropLayer
            contentLayer
        }
        .offset(x: horizontalDragOffset, y: max(0, dragOffset))
        .gesture(interactiveGestures)
        .colorScheme(.dark)
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.45), value: player.currentTrack?.id)
        .task(id: player.currentTrack?.id) {
            await loadLyrics()
        }
        .onReceive(player.$progress) { _ in
            updateCurrentLyricLine()
        }
        .sheet(isPresented: $showQueue) { QueueSheetView() }
        .sheet(isPresented: $showEQ) { PlayerEQSheetView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSleepTimer) { SleepTimerSheetView() }
        .fullScreenCover(isPresented: $showLyrics) { LyricsSheetView() }
    }

    // MARK: - Backdrop (абсолютно нейтральный к разметке)

    private var backdropLayer: some View {
        ZStack {
            AG.bg

            // Color.clear берёт ровно предложенный размер, а overlay никогда не влияет на размер
            // родителя — именно из-за отсутствия этого приёма прежний плеер расширялся за экран.
            Color.clear
                .overlay { artworkFill }
                .clipped()
                .id(currentTrack?.id)
                .transition(.opacity)

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.10), location: 0.0),
                    .init(color: Color.black.opacity(0.45), location: 0.40),
                    .init(color: AG.flame.opacity(0.30), location: 0.72),
                    .init(color: AG.bg.opacity(0.97), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.28)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var artworkFill: some View {
        if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
            blurredCover(Image(uiImage: img))
        } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    blurredCover(image)
                } else {
                    AnimatedMeshBackground(palette: palette)
                }
            }
        } else {
            AnimatedMeshBackground(palette: palette)
        }
    }

    private func blurredCover(_ image: Image) -> some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .saturation(1.14)
            .blur(radius: 42, opaque: true)
            .opacity(0.72)
    }

    // MARK: - Content

    private var contentLayer: some View {
        GeometryReader { geo in
            let side = max(120, min(geo.size.width, geo.size.height * 0.40))

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 6)

                coverImage
                    .frame(width: side, height: side)

                Spacer(minLength: 8)

                trackMetadataRow
                    .padding(.top, 10)

                if settings.showTeleprompterInPlayer, let line = currentLyricLine {
                    teleprompterText(line)
                        .padding(.top, 8)
                }

                timeScrubberSection
                    .padding(.top, 14)

                playbackControlsRow
                    .padding(.top, 6)

                volumeSliderSection
                    .padding(.top, 10)

                bottomUtilityIconsRow
                    .padding(.top, 8)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                close()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(AG.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(AG.hairline, lineWidth: 0.8))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            VStack(spacing: 5) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 34, height: 4)
                Text("СЕЙЧАС ИГРАЕТ")
                    .font(AG.text(9, .heavy))
                    .tracking(1.6)
                    .foregroundStyle(AG.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Menu {
                playerOptionsMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AG.ink)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .overlay(Circle().strokeBorder(AG.hairline, lineWidth: 0.8))
            }
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var playerOptionsMenu: some View {
        if let track = currentTrack, track.isStream {
            Button {
                Task { await library.saveOnlineTrackLocally(track: track) }
            } label: {
                Label("Скачать на iPhone", systemImage: "arrow.down.circle")
            }
        }

        Button { showEQ = true } label: {
            Label("Эквалайзер", systemImage: "slider.horizontal.3")
        }

        Button { showLyrics = true } label: {
            Label("Текст песни", systemImage: "quote.bubble")
        }

        Button { showQueue = true } label: {
            Label("Очередь", systemImage: "list.bullet")
        }

        Menu {
            ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                Button {
                    player.setSleepTimer(minutes: m)
                } label: {
                    Label(String(m) + " минут", systemImage: player.sleepTimerMinutes == m ? "checkmark" : "clock")
                }
            }
            if player.sleepTimerMinutes != nil {
                Divider()
                Button(role: .destructive) {
                    player.setSleepTimer(minutes: nil)
                } label: {
                    Label("Выключить таймер сна", systemImage: "moon.zzz")
                }
            }
        } label: {
            Label(sleepTimerLabel, systemImage: "moon.zzz")
        }

        Button { showSettings = true } label: {
            Label("Настройки", systemImage: "gearshape")
        }

        if let track = currentTrack, library.isTrackInLibrary(track) {
            Divider()
            Button(role: .destructive) {
                library.delete(track)
            } label: {
                Label("Удалить из медиатеки", systemImage: "trash")
            }
        }
    }

    // MARK: - Cover

    private func artworkFallback(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))
        }
    }

    private var coverImage: some View {
        Group {
            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        artworkFallback(size: 260)
                    }
                }
            } else {
                artworkFallback(size: 260)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AG.hairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.50), radius: 28, x: 0, y: 16)
        .matchedGeometryEffect(id: "heroArtwork", in: namespace)
    }

    // MARK: - Metadata

    private var trackMetadataRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                MarqueeText(
                    text: currentTrack?.title ?? "Sonivo",
                    font: AG.display(24, .heavy),
                    color: AG.ink
                )

                Text(currentTrack?.artist ?? "")
                    .font(AG.text(14, .medium))
                    .foregroundStyle(AG.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let track = currentTrack {
                Button {
                    if settings.hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    library.toggleFavorite(track)
                } label: {
                    Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(library.isTrackFavorite(track) ? AG.ember : AG.ink.opacity(0.80))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func teleprompterText(_ text: String) -> some View {
        Text(text)
            .font(AG.text(14, .semibold))
            .foregroundStyle(AG.ink)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .shadow(color: AG.amber.opacity(0.75), radius: 10)
            .allowsHitTesting(false)
    }

    private func loadLyrics() async {
        guard let track = player.currentTrack else {
            lyrics = nil
            currentLyricLine = nil
            return
        }
        do {
            lyrics = try await LyricsService.shared.fetchLyrics(for: track)
        } catch {
            lyrics = nil
        }
        updateCurrentLyricLine()
    }

    private func updateCurrentLyricLine() {
        guard let lyrics, lyrics.isSynchronized else {
            currentLyricLine = nil
            return
        }
        let t = player.progress + settings.lyricsOffset
        if let idx = lyrics.lines.firstIndex(where: { t >= $0.startTime && t < ($0.endTime ?? .greatestFiniteMagnitude) }) {
            currentLyricLine = lyrics.lines[idx].text
        } else {
            currentLyricLine = nil
        }
    }

    // MARK: - Scrubber

    private var timeScrubberSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let currentVal = scrubValue ?? player.progress
                let fraction = player.duration > 0 ? min(max(currentVal / player.duration, 0), 1) : 0
                let knob: CGFloat = isDraggingScrubber ? 15 : 9

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 5)

                    Capsule()
                        .fill(AG.emberGradient)
                        .frame(width: max(5, w * CGFloat(fraction)), height: 5)

                    Circle()
                        .fill(AG.ink)
                        .frame(width: knob, height: knob)
                        .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: min(max(0, w * CGFloat(fraction) - knob / 2), max(0, w - knob)))
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !isDraggingScrubber {
                                isDraggingScrubber = true
                                if settings.hapticsEnabled {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                            let newFrac = max(0, min(1, v.location.x / max(w, 1)))
                            scrubValue = Double(newFrac) * player.duration
                        }
                        .onEnded { v in
                            let newFrac = max(0, min(1, v.location.x / max(w, 1)))
                            player.seek(to: Double(newFrac) * player.duration)
                            scrubValue = nil
                            isDraggingScrubber = false
                        }
                )
            }
            .frame(height: 20)

            HStack(spacing: 8) {
                Text(player.formatted(scrubValue ?? player.progress))
                    .font(AG.text(11, .medium).monospacedDigit())
                    .foregroundStyle(AG.inkMuted)

                Spacer(minLength: 0)

                Menu {
                    ForEach(AudioQuality.allCases) { q in
                        Button {
                            player.selectQuality(q)
                        } label: {
                            Label(q.label, systemImage: player.audioQuality == q ? "checkmark" : "waveform")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                        Text(qualityLabel)
                            .font(AG.text(10, .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(AG.amber)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(AG.amber.opacity(0.14)))
                }

                Spacer(minLength: 0)

                Text("-" + player.formatted(max(0, player.duration - (scrubValue ?? player.progress))))
                    .font(AG.text(11, .medium).monospacedDigit())
                    .foregroundStyle(AG.inkMuted)
            }
        }
    }

    // MARK: - Controls

    private var playbackControlsRow: some View {
        HStack(spacing: 0) {
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(AG.ink)
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(AG.emberGradient))
                    .shadow(color: AG.ember.opacity(0.45), radius: 18, y: 8)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(AG.ink)
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    private var volumeSliderSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AG.inkMuted)

            SystemVolumeSlider(tintColor: UIColor(AG.amber))
                .frame(height: 30)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AG.inkMuted)
        }
    }

    private var bottomUtilityIconsRow: some View {
        HStack(spacing: 0) {
            utilityButton(icon: "quote.bubble", active: false) { showLyrics = true }

            Spacer(minLength: 0)

            AirPlayButtonView()
                .frame(width: 42, height: 42)

            Spacer(minLength: 0)

            utilityButton(icon: "list.bullet", active: false) { showQueue = true }

            Spacer(minLength: 0)

            Button {
                showSleepTimer = true
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: player.sleepTimerMinutes != nil ? "moon.zzz.fill" : "moon.zzz")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(player.sleepTimerMinutes != nil ? AG.amber : AG.ink.opacity(0.72))
                    if player.sleepTimerMinutes != nil {
                        Text(sleepTimerShortLabel)
                            .font(AG.text(8, .semibold))
                            .foregroundStyle(AG.amber.opacity(0.9))
                    }
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
        }
    }

    private func utilityButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? AG.amber : AG.ink.opacity(0.72))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gestures

    private func close() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            isPresented = false
        }
    }

    private var interactiveGestures: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                if abs(v.translation.width) > abs(v.translation.height) {
                    horizontalDragOffset = v.translation.width * 0.22
                } else if v.translation.height > 0 {
                    dragOffset = v.translation.height
                }
            }
            .onEnded { v in
                let threshold = UIScreen.main.bounds.width * 0.35

                if v.translation.width < -threshold {
                    if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    player.next()
                } else if v.translation.width > threshold {
                    if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    player.previous()
                }

                if v.translation.height > 110 {
                    close()
                }

                withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                    dragOffset = 0
                    horizontalDragOffset = 0
                }
            }
    }
}

// MARK: - AirPlay Button Wrapper

struct AirPlayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.75)
        picker.activeTintColor = UIColor(AG.amber)
        picker.prioritizesVideoDevices = false
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - System Volume Slider

struct SystemVolumeSlider: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.tintColor = tintColor
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = tintColor
    }
}
