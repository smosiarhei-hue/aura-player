import AVKit
import MediaPlayer
import SwiftUI

// MARK: - Apple Music Exact Fullscreen Player (Liquid Glass iOS 27)

struct PlayerScreen: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
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
    private var palette: [Color] {
        currentTrack?.palette ?? Palette.seeded(42).colors
    }

    private var qualityLabel: String {
        if let br = player.currentBitrate { return "\(br) kbps" }
        return "HQ"
    }

    private var sleepTimerLabel: String {
        guard let remaining = player.sleepTimerRemaining else { return "Таймер сна" }
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "Таймер сна • %d:%02d", m, s)
    }

    private var sleepTimerShortLabel: String {
        guard let remaining = player.sleepTimerRemaining else { return "" }
        let m = Int(remaining) / 60
        let s = Int(remaining) % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Immersive full-bleed album artwork wallpaper
                artworkBackground(geo: geo)

                VStack(spacing: 0) {
                    // Top Drag Indicator & Settings Quick Access
                    topGrabber
                        .padding(.top, max(geo.safeAreaInsets.top, 8))
                        .padding(.horizontal, 8)

                    Spacer(minLength: 6)

                    // Big expansive cover (aspectFit, no top/bottom crop)
                    heroArtwork
                        .padding(.horizontal, 28)
                        .padding(.top, 4)

                    Spacer(minLength: 6)

                    // Title + artist + star + menu
                    trackMetadataRow
                        .padding(.horizontal, 24)
                        .padding(.top, 14)

                    // Small glow teleprompter near the time code
                    if settings.showTeleprompterInPlayer, let line = currentLyricLine {
                        teleprompterText(line)
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                    }

                    // Apple Music Time Scrubber & Audio Format Badge
                    timeScrubberSection
                        .padding(.horizontal, 28)
                        .padding(.top, 14)

                    // Iconic Huge Playback Controls
                    playbackControlsRow
                        .padding(.horizontal, 36)
                        .padding(.top, 12)

                    // System Volume Slider (MPVolumeView)
                    volumeSliderSection
                        .padding(.horizontal, 28)
                        .padding(.top, 16)

                    // Bottom Navigation Bar
                    bottomUtilityIconsRow
                        .padding(.horizontal, 32)
                        .padding(.top, 14)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                }
            }
            .offset(y: max(0, dragOffset))
            .gesture(interactiveGestures)
        }
        .colorScheme(.dark)
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.5), value: player.currentTrack?.id)
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

    // MARK: - Artwork Background

    @ViewBuilder
    private func artworkBackground(geo: GeometryProxy) -> some View {
        ZStack {
            Color(red: 0.05, green: 0.08, blue: 0.10).ignoresSafeArea()

            driftingArtwork(geo: geo)
                .ignoresSafeArea()
                .id(currentTrack?.id)
                .transition(.opacity)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.15), location: 0.45),
                    .init(color: (palette.first ?? .teal).opacity(0.65), location: 0.70),
                    .init(color: Color(red: 0.03, green: 0.08, blue: 0.10).opacity(0.95), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.40)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func driftingArtwork(geo: GeometryProxy) -> some View {
        if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
            radialBlurArtwork(Image(uiImage: img), geo: geo, scale: 1.0)
        } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    radialBlurArtwork(image, geo: geo, scale: 1.0)
                } else {
                    AnimatedMeshBackground(palette: palette)
                }
            }
        } else {
            AnimatedMeshBackground(palette: palette)
        }
    }

    // Sharp artwork in the center, blurred only toward the edges (radial mask).
    @ViewBuilder
    private func radialBlurArtwork(_ image: Image, geo: GeometryProxy, scale: CGFloat) -> some View {
        let dim = max(geo.size.width, geo.size.height)
        ZStack {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(scale)
                .saturation(1.12)
                .clipped()
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(scale)
                .saturation(1.12)
                .blur(radius: 34)
                .mask(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.45),
                            .init(color: .black, location: 1.0)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: dim * 0.55
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .clipped()
    }

    // MARK: - Top Grabber

    private var topGrabber: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Capsule()
                .fill(.white.opacity(0.30))
                .frame(width: 36, height: 5)

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Artwork Fallback

    private func artworkFallback(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: palette,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
    }

    // Big full cover (generous expansive presentation).
    private var heroArtwork: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            coverImage
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: 350)
    }

    private var coverImage: some View {
        Group {
            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        artworkFallback(size: 280)
                    }
                }
            } else {
                artworkFallback(size: 280)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 14)
        .matchedGeometryEffect(id: "heroArtwork", in: namespace)
    }

    private var trackMetadataRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MarqueeText(text: currentTrack?.title ?? "Sonivo Player",
                                font: .title2.weight(.bold),
                                color: .white)

                    Text("E")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.85)))
                }

                Text(currentTrack?.artist ?? "Apple Music Experience")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
            }

            Spacer()

            if let track = currentTrack {
                Button {
                    if settings.hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    library.toggleFavorite(track)
                } label: {
                    Image(systemName: library.isTrackFavorite(track) ? "star.fill" : "star")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(library.isTrackFavorite(track) ? .yellow : .white.opacity(0.85))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }

            Menu {
                if let track = currentTrack, track.isStream {
                    Button {
                        Task { await library.saveOnlineTrackLocally(track: track) }
                    } label: {
                        Label("Скачать на iPhone", systemImage: "arrow.down.circle")
                    }
                }

                Button {
                    showEQ = true
                } label: {
                    Label("Эквалайзер", systemImage: "slider.horizontal.3")
                }

                Button {
                    showLyrics = true
                } label: {
                    Label("Текст песни", systemImage: "quote.bubble")
                }

                Menu {
                    ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                        Button {
                            player.setSleepTimer(minutes: m)
                        } label: {
                            Label("\(m) минут", systemImage: player.sleepTimerMinutes == m ? "checkmark" : "clock")
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

                if let track = currentTrack, library.isTrackInLibrary(track) {
                    Button(role: .destructive) {
                        library.delete(track)
                    } label: {
                        Label("Удалить из медиатеки", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
            }
        }
    }

    // MARK: - Karaoke Teleprompter

    @ViewBuilder
    private func teleprompterText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .shadow(color: (palette.first ?? .white).opacity(0.9), radius: 10)
            .shadow(color: (palette.first ?? .white).opacity(0.55), radius: 22)
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

    // MARK: - Time Scrubber

    private var timeScrubberSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let currentVal = scrubValue ?? player.progress
                let fraction = player.duration > 0 ? min(max(currentVal / player.duration, 0), 1) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.20))
                        .frame(height: 5)

                    Capsule()
                        .fill(.white.opacity(0.95))
                        .frame(width: max(5, w * CGFloat(fraction)), height: 5)

                    Circle()
                        .fill(.white)
                        .frame(width: isDraggingScrubber ? 16 : 8, height: isDraggingScrubber ? 16 : 8)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: min(max(0, w * CGFloat(fraction) - (isDraggingScrubber ? 8 : 4)), w - (isDraggingScrubber ? 16 : 8)))
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
                            let seekTarget = Double(newFrac) * player.duration
                            player.seek(to: seekTarget)
                            scrubValue = nil
                            isDraggingScrubber = false
                        }
                )
            }
            .frame(height: 20)

            HStack {
                Text(player.formatted(scrubValue ?? player.progress))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))

                Spacer()

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
                            .font(.system(size: 10, weight: .bold))
                        Text(qualityLabel)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.70))
                }

                Spacer()

                Text("-" + player.formatted(max(0, player.duration - (scrubValue ?? player.progress))))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: - Playback Controls

    private var playbackControlsRow: some View {
        HStack(spacing: 0) {
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Volume Slider

    private var volumeSliderSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))

            SystemVolumeSlider(tintColor: .white)
                .frame(height: 32)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    // MARK: - Bottom Utility Icons

    private var bottomUtilityIconsRow: some View {
        HStack {
            Button {
                showLyrics = true
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            AirPlayButtonView()
                .frame(width: 44, height: 44)

            Spacer()

            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showSleepTimer = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: player.sleepTimerMinutes != nil ? "moon.zzz.fill" : "moon.zzz")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(player.sleepTimerMinutes != nil ? .yellow : .white.opacity(0.75))
                    if player.sleepTimerMinutes != nil {
                        Text(sleepTimerShortLabel)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.yellow.opacity(0.9))
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Interactive Gestures

    private var interactiveGestures: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { v in
                if abs(v.translation.width) > abs(v.translation.height) {
                    horizontalDragOffset = v.translation.width * 0.3
                } else if v.translation.height > 0 {
                    dragOffset = v.translation.height
                }
            }
            .onEnded { v in
                let screenW = UIScreen.main.bounds.width
                let threshold = screenW * 0.35

                if v.translation.width < -threshold {
                    if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        player.next()
                    }
                } else if v.translation.width > threshold {
                    if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        player.previous()
                    }
                }

                if v.translation.height > 100 {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        isPresented = false
                    }
                }

                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    dragOffset = 0
                    horizontalDragOffset = 0
                }
            }
    }
}

// MARK: - AirPlay Button Wrapper (AVRoutePickerView)

struct AirPlayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.75)
        picker.activeTintColor = UIColor.systemTeal
        picker.prioritizesVideoDevices = false
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - System Volume Slider (MPVolumeView)

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

// MARK: - Lyrics Sheet View with Synchronized Karaoke

struct LyricsSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: Lyrics?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            karaokeBackdrop

            LyricsView(lyrics: lyrics, isLoading: isLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "Текст песни")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .colorScheme(.dark)
        .task(id: player.currentTrack?.id) {
            await load()
        }
    }

    @ViewBuilder
    private var karaokeBackdrop: some View {
        ZStack {
            Color.black
            if let track = player.currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60)
                    .opacity(0.45)
            } else if let track = player.currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill).blur(radius: 60).opacity(0.45)
                    } else {
                        LinearGradient(colors: track.palette, startPoint: .top, endPoint: .bottom)
                    }
                }
            } else {
                LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.14), .black],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private func load() async {
        guard let track = player.currentTrack else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            lyrics = try await LyricsService.shared.fetchLyrics(for: track)
        } catch {
            lyrics = nil
        }
    }
}

// MARK: - Marquee Title

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MarqueeText: View {
    let text: String
    var font: Font = .title2.weight(.bold)
    var color: Color = .white

    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        GeometryReader { container in
            let overflow = max(0, textWidth - container.size.width + 12)
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: geo.size.width)
                    }
                )
                .offset(x: animate ? -overflow : 0)
                .frame(width: container.size.width, alignment: .leading)
                .clipped()
                .animation(
                    overflow > 0 ? .easeInOut(duration: 4).repeatForever(autoreverses: true).delay(1.2) : nil,
                    value: animate
                )
                .onAppear { if overflow > 0 { animate = true } }
        }
        .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
        .frame(height: 34)
    }
}

// MARK: - Sleep Timer Sheet

struct SleepTimerSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 30

    private let options = [5, 10, 15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Время", selection: $minutes) {
                    ForEach(options, id: \.self) { m in
                        Text("\(m) мин").tag(m)
                    }
                }
                .pickerStyle(.wheel)

                if player.sleepTimerMinutes != nil {
                    Button(role: .destructive) {
                        player.setSleepTimer(minutes: nil)
                        dismiss()
                    } label: {
                        Label("Выключить таймер сна", systemImage: "moon.zzz")
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Таймер сна")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        player.setSleepTimer(minutes: minutes)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}

// MARK: - Queue Sheet View

struct QueueSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let cur = player.currentTrack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("СЕЙЧАС ИГРАЕТ")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)

                            HStack(spacing: 12) {
                                SmallArtwork(track: cur, size: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cur.title).font(.body.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                                    Text(cur.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "waveform")
                                    .foregroundStyle(SettingsStore.shared.accentColor)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                            .padding(.horizontal, 12)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ДАЛЕЕ В ОЧЕРЕДИ (\(player.queue.count))")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        if player.queue.isEmpty {
                            Text("Очередь пуста. Выберите треки из каталога или медиатеки.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            LazyVStack(spacing: 2) {
                                ForEach(player.queue) { track in
                                    Button {
                                        player.play(track)
                                    } label: {
                                        HStack(spacing: 12) {
                                            SmallArtwork(track: track, size: 44)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(track.title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer()
                                            if player.currentTrack?.id == track.id {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(SettingsStore.shared.accentColor)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            player.removeFromQueue(track)
                                        } label: {
                                            Label("Удалить из очереди", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("Очередь воспроизведения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Player EQ Sheet View

struct PlayerEQSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    private let freqLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Toggle(isOn: $player.eqEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("10-полосный эквалайзер")
                                .font(.headline.weight(.semibold))
                            Text("31 Гц – 16 кГц · тонкая настройка звука")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(settings.accentColor)
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Пресеты").font(.subheadline.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(EQPresets.all) { preset in
                                    let isActive = player.eqGains == preset.gains
                                    Button {
                                        withAnimation(.spring(response: 0.3)) {
                                            player.eqGains = preset.gains
                                        }
                                    } label: {
                                        Text(preset.name)
                                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(
                                                Capsule().fill(isActive
                                                    ? AnyShapeStyle(settings.accentGradient)
                                                    : AnyShapeStyle(.primary.opacity(0.08)))
                                            )
                                            .foregroundStyle(isActive ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 12) {
                        HStack {
                            Text("Полосы частот").font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Сбросить") {
                                withAnimation { player.eqGains = EQPresets.flat.gains }
                            }
                            .font(.caption)
                        }
                        HStack(alignment: .center, spacing: 6) {
                            ForEach(0..<10, id: \.self) { i in
                                BandSlider(
                                    label: freqLabels[i],
                                    value: Binding(get: { player.eqGains[i] }, set: { player.eqGains[i] = $0 })
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Band Slider Component

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 6)
                    let fraction = CGFloat((value + 12) / 24)
                    Capsule()
                        .fill(LinearGradient(colors: SettingsStore.shared.accent.colors, startPoint: .bottom, endPoint: .top))
                        .frame(width: 6, height: max(6, fraction * h))
                }
                .frame(height: h).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let f = 1 - Float(min(max(v.location.y / h, 0), 1))
                            value = f * 24 - 12
                        }
                )

                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 160)
    }
}
