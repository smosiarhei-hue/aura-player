import AVKit
import MediaPlayer
import SwiftUI

// MARK: - Player Screen (Apple Music Liquid Glass Experience)

struct PlayerScreen: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var scrubValue: Double? = nil
    @State private var isDraggingScrubber = false
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var dragOffset: CGFloat = 0

    private var palette: [Color] {
        player.currentTrack?.palette ?? Palette.seeded(42).colors
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Animated Apple Music full-screen mesh background
                AnimatedMeshBackground(palette: palette)

                VStack(spacing: 0) {
                    // Top Bar (Grabber / Header)
                    topBar
                        .padding(.top, max(geo.safeAreaInsets.top, 12))
                        .padding(.horizontal, 20)

                    Spacer(minLength: 12)

                    // Album Artwork Card (scales up on play, down on pause)
                    let artSize = min(geo.size.width - 64, geo.size.height * 0.38)
                    TrackArtworkView(
                        track: player.currentTrack,
                        isPlaying: player.isPlaying,
                        size: max(220, artSize)
                    )
                    .padding(.vertical, 8)

                    Spacer(minLength: 12)

                    // Track Meta & Favorite Button
                    trackInfoSection
                        .padding(.horizontal, 28)

                    // Timeline Scrubber
                    timelineScrubber
                        .padding(.horizontal, 28)
                        .padding(.top, 16)

                    // Main Controls (Shuffle, Prev, Play/Pause, Next, Repeat)
                    mainControls
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                    // Volume Bar (Apple Music style)
                    volumeSection
                        .padding(.horizontal, 28)
                        .padding(.top, 22)

                    // Bottom Utility Row (AirPlay, EQ, Queue)
                    bottomUtilityRow
                        .padding(.horizontal, 32)
                        .padding(.top, 18)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                }
            }
            .offset(y: max(0, dragOffset))
            .gesture(dismissGesture)
        }
        .colorScheme(.dark)
        .statusBarHidden()
        .sheet(isPresented: $showQueue) { QueueSheet() }
        .sheet(isPresented: $showEQ) { PlayerEQSheet() }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: 36, height: 4)

            Spacer()

            Button { showEQ = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Track Info & Favorite

    private var trackInfoSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.title ?? "Ничего не играет")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(player.currentTrack?.artist ?? "Aurora Player")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            if let track = player.currentTrack {
                Button {
                    if settings.hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    LibraryStore.shared.toggleFavorite(track.id)
                } label: {
                    Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(track.isFavorite ? .pink : .white.opacity(0.75))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Timeline Scrubber

    private var timelineScrubber: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let currentVal = scrubValue ?? player.progress
                let fraction = player.duration > 0 ? min(max(currentVal / player.duration, 0), 1) : 0

                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(.white.opacity(0.20))
                        .frame(height: 6)

                    // Track filled progress
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white, settings.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, w * CGFloat(fraction)), height: 6)

                    // Draggable knob
                    Circle()
                        .fill(.white)
                        .frame(width: isDraggingScrubber ? 18 : 12, height: isDraggingScrubber ? 18 : 12)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .offset(x: min(max(0, w * CGFloat(fraction) - (isDraggingScrubber ? 9 : 6)), w - (isDraggingScrubber ? 18 : 12)))
                }
                .frame(height: 24)
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
            .frame(height: 24)

            HStack {
                Text(player.formatted(scrubValue ?? player.progress))
                Spacer()
                Text("-" + player.formatted(player.duration - (scrubValue ?? player.progress)))
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: - Main Controls

    private var mainControls: some View {
        HStack(spacing: 0) {
            // Shuffle
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 19, weight: player.shuffle ? .bold : .medium))
                    .foregroundStyle(player.shuffle ? settings.accentColor : .white.opacity(0.7))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)

            Spacer()

            // Previous
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)

            Spacer()

            // Play / Pause (Big tactile button)
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                player.togglePlay()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)

                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Next
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)

            Spacer()

            // Repeat
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                player.repeatMode = RepeatMode(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
            } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 19, weight: player.repeatMode != .off ? .bold : .medium))
                    .foregroundStyle(player.repeatMode != .off ? settings.accentColor : .white.opacity(0.7))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Volume Section (Apple Music Liquid Glass Slider)

    private var volumeSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            GeometryReader { geo in
                let w = geo.size.width
                let frac = CGFloat(max(0, min(1, player.volume)))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.20))
                        .frame(height: 6)

                    Capsule()
                        .fill(.white.opacity(0.90))
                        .frame(width: max(6, w * frac), height: 6)

                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: min(max(0, w * frac - 7), w - 14))
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Bottom Utility Row (AirPlay & Queue)

    private var bottomUtilityRow: some View {
        HStack {
            // Live Spectrum visualizer indicator
            if player.isPlaying {
                SpectrumView(barWidth: 3, maxHeight: 20)
                    .frame(width: 80)
            } else {
                Color.clear.frame(width: 80, height: 20)
            }

            Spacer()

            // Queue Sheet button
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Dismiss Gesture

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                if v.translation.height > 0 {
                    dragOffset = v.translation.height
                }
            }
            .onEnded { v in
                if v.translation.height > 100 {
                    dismiss()
                }
                dragOffset = 0
            }
    }
}

// MARK: - Player EQ Sheet

struct PlayerEQSheet: View {
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

                    // Live Spectrum Bar
                    if player.isPlaying {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Живой спектр").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            SpectrumView(barWidth: 5, maxHeight: 56)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.horizontal, 20)
                    }

                    // Presets Scroller
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

                    // 10-Band Vertical Sliders
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

// MARK: - Band Slider

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(.primary.opacity(0.12)).frame(width: 6)
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

// MARK: - Queue Sheet

struct QueueSheet: View {
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
