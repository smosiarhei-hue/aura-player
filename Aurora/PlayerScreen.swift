import AVKit
import MediaPlayer
import SwiftUI

// MARK: - Apple Music Exact Fullscreen Player (Liquid Glass iOS 27)

struct PlayerScreen: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var scrubValue: Double? = nil
    @State private var isDraggingScrubber = false
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var dragOffset: CGFloat = 0

    private var currentTrack: Track? { player.currentTrack }
    private var palette: [Color] {
        currentTrack?.palette ?? Palette.seeded(42).colors
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Immersive full-bleed album artwork with seamless downward gradient blur (Screenshot 1)
                artworkBackground(geo: geo)

                VStack(spacing: 0) {
                    // Top Drag Indicator (Chevron / Grabber)
                    topGrabber
                        .padding(.top, max(geo.safeAreaInsets.top, 8))

                    Spacer(minLength: 10)

                    // Hero Album Artwork
                    let artSize = min(geo.size.width - 64, geo.size.height * 0.42)
                    artworkHero(size: max(240, artSize))
                        .padding(.vertical, 8)

                    Spacer(minLength: 10)

                    // Track Title, Explicit Badge, Artist, Star & Options
                    trackMetadataRow
                        .padding(.horizontal, 28)

                    // Apple Music Time Scrubber & Audio Format Badge
                    timeScrubberSection
                        .padding(.horizontal, 28)
                        .padding(.top, 16)

                    // Iconic Huge Playback Controls (Prev, Play/Pause, Next)
                    playbackControlsRow
                        .padding(.horizontal, 36)
                        .padding(.top, 20)

                    // Apple Music Capsule Volume Slider
                    volumeSliderSection
                        .padding(.horizontal, 28)
                        .padding(.top, 24)

                    // Bottom Navigation Bar (Lyrics, AirPlay, Queue)
                    bottomUtilityIconsRow
                        .padding(.horizontal, 42)
                        .padding(.top, 24)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 20))
                }
            }
            .offset(y: max(0, dragOffset))
            .gesture(dismissGesture)
        }
        .colorScheme(.dark)
        .statusBarHidden()
        .sheet(isPresented: $showLyrics) { LyricsSheetView() }
        .sheet(isPresented: $showQueue) { QueueSheetView() }
        .sheet(isPresented: $showEQ) { PlayerEQSheetView() }
    }

    // MARK: - Artwork Background (Exact Apple Music Wallpaper)

    @ViewBuilder
    private func artworkBackground(geo: GeometryProxy) -> some View {
        ZStack {
            // Base background
            Color(red: 0.05, green: 0.08, blue: 0.10).ignoresSafeArea()

            // Large scaled artwork in top half
            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height * 0.70)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.28)
                    .blur(radius: 2)
            } else {
                AnimatedMeshBackground(palette: palette)
            }

            // Downward smooth gradient & liquid blur (Screenshot 1)
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

            // Frosted ambient overlay
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.40)
                .ignoresSafeArea()
        }
    }

    // MARK: - Top Grabber

    private var topGrabber: some View {
        HStack {
            Button { dismiss() } label: {
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

            Button { showEQ = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Artwork Hero Card

    private func artworkHero(size: CGFloat) -> some View {
        Group {
            if let track = currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
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
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: player.isPlaying ? 28 : 12, x: 0, y: player.isPlaying ? 18 : 6)
        .scaleEffect(player.isPlaying ? 1.0 : 0.88)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: player.isPlaying)
    }

    // MARK: - Track Metadata Row (Title, Explicit badge, Star, Dots)

    private var trackMetadataRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(currentTrack?.title ?? "Aurora Player")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    // Explicit [E] Badge
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

            // Star Favorite Button (Screenshot 1: ☆ / ★)
            if let track = currentTrack {
                Button {
                    if settings.hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    library.toggleFavorite(track.id)
                } label: {
                    Image(systemName: track.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(track.isFavorite ? .yellow : .white.opacity(0.85))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }

            // Three Dots Context Menu
            Menu {
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

                if let track = currentTrack {
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

    // MARK: - Apple Music Time Scrubber & Dolby Atmos Badge

    private var timeScrubberSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let currentVal = scrubValue ?? player.progress
                let fraction = player.duration > 0 ? min(max(currentVal / player.duration, 0), 1) : 0

                ZStack(alignment: .leading) {
                    // Track Unfilled Background
                    Capsule()
                        .fill(.white.opacity(0.20))
                        .frame(height: 5)

                    // Track Filled Progress
                    Capsule()
                        .fill(.white.opacity(0.95))
                        .frame(width: max(5, w * CGFloat(fraction)), height: 5)

                    // Scrubber Knob (Apple Music style)
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
                            if settings.scrubHapticsEnabled {
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                        }
                        .onEnded { _ in
                            if let s = scrubValue {
                                player.seek(to: s)
                                scrubValue = nil
                            }
                            isDraggingScrubber = false
                        }
                )
            }
            .frame(height: 20)

            // Times + Dolby Atmos / Lossless Badge (Screenshot 1)
            HStack {
                Text(player.formatted(scrubValue ?? player.progress))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))

                Spacer()

                // Center Audio Badge (Dolby Atmos / Hi-Res Lossless)
                HStack(spacing: 4) {
                    Image(systemName: "dolby.audio.badge")
                        .font(.system(size: 11, weight: .bold))
                    Text("Dolby Atmos")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.55))

                Spacer()

                Text("-" + player.formatted(player.duration - (scrubValue ?? player.progress)))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    // MARK: - Playback Controls (Previous, Play/Pause, Next)

    private var playbackControlsRow: some View {
        HStack(spacing: 0) {
            // Previous Track
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

            // Big Bold Pause/Play Button (Screenshot 1)
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

            // Next Track
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

    // MARK: - Volume Slider (Apple Music Capsule)

    private var volumeSliderSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))

            GeometryReader { geo in
                let w = geo.size.width
                let frac = CGFloat(max(0, min(1, player.volume)))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.20))
                        .frame(height: 7)

                    Capsule()
                        .fill(.white.opacity(0.90))
                        .frame(width: max(7, w * frac), height: 7)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let newFrac = max(0, min(1, v.location.x / max(w, 1)))
                            player.volume = Float(newFrac)
                        }
                )
            }
            .frame(height: 24)

            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    // MARK: - Bottom Utility Icons (Lyrics, AirPlay, Queue - Screenshot 1)

    private var bottomUtilityIconsRow: some View {
        HStack {
            // Lyrics Button
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

            // AirPlay Route Picker
            AirPlayButtonView()
                .frame(width: 44, height: 44)

            Spacer()

            // Queue List Button
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Dismiss Gesture

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                if v.translation.height > 0 { dragOffset = v.translation.height }
            }
            .onEnded { v in
                if v.translation.height > 100 { dismiss() }
                dragOffset = 0
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

// MARK: - Lyrics Sheet View

struct LyricsSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.opacity(0.95).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text(player.currentTrack?.title ?? "Текст песни")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Текст песни синхронизируется в реальном времени при наличии в метаданных трека.\n\nEnjoy pure music with Aurora Liquid Glass Audio Engine.")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineSpacing(10)
                    }
                    .padding(28)
                }
            }
            .navigationTitle("Текст песни")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Queue Sheet View

struct QueueSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(player.queue) { track in
                        Button { player.play(track) } label: {
                            HStack(spacing: 12) {
                                SmallArtwork(track: track, size: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if player.currentTrack?.id == track.id {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(SettingsStore.shared.accentColor)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)
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
