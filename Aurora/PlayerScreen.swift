import AVKit
import MediaPlayer
import SwiftUI

// MARK: - Apple Music Exact Fullscreen Player (Liquid Glass iOS 27)

struct PlayerScreen: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var analyzer = SpectrumAnalyzer.shared
    @Binding var isPresented: Bool
    let namespace: Namespace.ID

    @State private var scrubValue: Double? = nil
    @State private var isDraggingScrubber = false
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var showSettings = false
    @State private var dragOffset: CGFloat = 0
    @State private var horizontalDragOffset: CGFloat = 0
    @State private var controlsVisible = true
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

    private var bassEnergy: Double { Double(analyzer.bass) }

    /// Real bass energy when the local EQ tap has signal; otherwise a subtle
    /// time-based pulse so streaming tracks (AVPlayer, no analyzer tap) still
    /// visibly move with the beat (~96 BPM fallback).
    private func effectiveBass(at time: TimeInterval) -> Double {
        let raw = max(bassEnergy, Double(analyzer.streamLevel))
        if raw > 0.03 { return raw }
        guard player.isPlaying else { return 0 }
        let pulse = 0.5 + 0.5 * sin(time * 2.0 * .pi * 1.6)
        return 0.18 + 0.82 * pulse
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Immersive full-bleed album artwork wallpaper (Screenshot 1)
                artworkBackground(geo: geo)

                VStack(spacing: 0) {
                    // Top Drag Indicator & Settings Quick Access
                    topGrabber
                        .padding(.top, max(geo.safeAreaInsets.top, 8))
                        .padding(.horizontal, 8)

                    Spacer(minLength: 8)

                    // Big centered hero cover (standard play/pause animation + hero transition)
                    let artSize = min(geo.size.width - 72, geo.size.height * 0.30)
                    artworkHero(size: max(150, artSize))
                        .offset(x: horizontalDragOffset)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                controlsVisible.toggle()
                            }
                        }

                    Spacer(minLength: 14)

                    if controlsVisible {
                        // Title + small cover + artist + star + menu (back below the cover)
                        trackMetadataRow
                            .padding(.horizontal, 24)

                        // Subtle blurry karaoke teleprompter line
                        if let line = currentLyricLine {
                            teleprompterText(line)
                                .padding(.horizontal, 32)
                                .padding(.top, 14)
                        }

                        // Apple Music Time Scrubber & Audio Format Badge
                        timeScrubberSection
                            .padding(.horizontal, 28)
                            .padding(.top, 14)

                        // Iconic Huge Playback Controls (Prev, Play/Pause, Next)
                        playbackControlsRow
                            .padding(.horizontal, 36)
                            .padding(.top, 8)

                        // System Volume Slider (MPVolumeView)
                        volumeSliderSection
                            .padding(.horizontal, 28)
                            .padding(.top, 10)

                        // Bottom Navigation Bar (Lyrics, AirPlay, Queue, Sleep Timer)
                        bottomUtilityIconsRow
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                    } else {
                        Spacer(minLength: 40)
                    }
                }
            }
            .offset(y: max(0, dragOffset))
            .gesture(interactiveGestures)
        }
        .colorScheme(.dark)
        .statusBarHidden()
        .task(id: player.currentTrack?.id) {
            await loadLyrics()
        }
        .onReceive(player.$progress) { _ in
            updateCurrentLyricLine()
        }
        .sheet(isPresented: $showLyrics) { LyricsSheetView() }
        .sheet(isPresented: $showQueue) { QueueSheetView() }
        .sheet(isPresented: $showEQ) { PlayerEQSheetView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Artwork Background (Exact Apple Music Wallpaper)

    @ViewBuilder
    private func artworkBackground(geo: GeometryProxy) -> some View {
        ZStack {
            Color(red: 0.05, green: 0.08, blue: 0.10).ignoresSafeArea()

            driftingArtwork(geo: geo)

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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let drift: CGFloat = 1.0 + max(0, sin(t * 0.4)) * 0.04
            let bass = effectiveBass(at: t)
            let beatBoost: CGFloat = player.isPlaying ? 1.0 + CGFloat(bass) * 0.07 : 1.0
            let scale = drift * beatBoost

            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                radialBlurArtwork(Image(uiImage: img), geo: geo, scale: scale)
            } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        radialBlurArtwork(image, geo: geo, scale: scale)
                    } else {
                        AnimatedMeshBackground(palette: palette)
                    }
                }
            } else {
                AnimatedMeshBackground(palette: palette)
            }
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
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .saturation(1.12)
                .clipped()
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
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
        .clipped()
    }

    // MARK: - Top Grabber

    private var topGrabber: some View {
        HStack {
            Button { isPresented = false } label: {
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

    // MARK: - Track Metadata Row (Favorite & Context Menu)

    // Big centered hero cover — standard play/pause animation (no beat jump),
    // hero-matched to the mini player cover for a clean open/close morph.
    private func artworkHero(size: CGFloat) -> some View {
        Group {
            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        artworkFallback(size: size)
                    }
                }
            } else {
                artworkFallback(size: size)
            }
        }
        .frame(width: size, height: size)
        .matchedGeometryEffect(id: "heroArtwork", in: namespace)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: (palette.first ?? .white).opacity(0.28), radius: 24, x: 0, y: 12)
        .scaleEffect(player.isPlaying ? 1.0 : 0.90)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: player.isPlaying)
    }

    // Small thumbnail beside the title (no hero transition, no beat pulse).
    private var smallCover: some View {
        Group {
            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let track = currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        artworkFallback(size: 56)
                    }
                }
            } else {
                artworkFallback(size: 56)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var trackMetadataRow: some View {
        HStack(alignment: .center, spacing: 14) {
            // Small artwork thumbnail beside the title
            smallCover

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(currentTrack?.title ?? "Sonivo Player")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

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

    // MARK: - Karaoke Teleprompter (subtle blurry running text)

    @ViewBuilder
    private func teleprompterText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white.opacity(0.28))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .blur(radius: 2.5)
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

    // MARK: - Time Scrubber (Accurate non-resetting seek)

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

                HStack(spacing: 4) {
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

            // Visible sleep timer (moon) — always in the player, not buried in the ••• menu
            Menu {
                ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                    Button {
                        if settings.hapticsEnabled {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
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
        }
    }

    // MARK: - Interactive Gestures (Swipe down to dismiss, Swipe left/right for tracks)

    private var interactiveGestures: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { v in
                if abs(v.translation.width) > abs(v.translation.height) {
                    horizontalDragOffset = v.translation.width * 0.3
                } else if v.translation.height > 0 {
                    dragOffset = v.translation.height
                }
            }
            .onEnded { v in
                let screenW = UIScreen.main.bounds.width
                let threshold = screenW * 0.45

                // Horizontal Swipe (Next / Previous Track) — requires a deliberate full swipe
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

                // Vertical Dismiss
                if v.translation.height > 120 {
                    isPresented = false
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

// MARK: - System Volume Slider (MPVolumeView, bound to device volume)

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
        NavigationStack {
            ZStack {
                if let track = player.currentTrack {
                    LinearGradient(colors: track.palette.prefix(2).map { $0 },
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(0.25)
                        .ignoresSafeArea()
                }

                LyricsView(lyrics: lyrics, isLoading: isLoading)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Текст песни")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .task(id: player.currentTrack?.id) {
            await load()
        }
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

// MARK: - Queue Sheet View with Full "Now Playing" and "Up Next"

struct QueueSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Currently Playing
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

                    // Up Next
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

                    // Presets
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

                    // 10-Band Sliders
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
