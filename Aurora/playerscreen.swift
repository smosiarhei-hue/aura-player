import SwiftUI

struct PlayerScreen: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var analyzer = SpectrumAnalyzer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGSize = .zero
    @State private var scrubValue: Double? = nil
    @State private var showQueue = false

    var body: some View {
        ZStack {
            BackdropView(palette: currentPalette)
            content
                .offset(y: max(0, dragOffset.height))
                .opacity(1 - min(0.5, Double(dragOffset.height / 400)))
        }
        .statusBarHidden()
        .colorScheme(.dark)
        .gesture(dragGesture)
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    private var currentPalette: [Color] { player.currentTrack?.palette ?? Palette.seeded(42).colors }
    private var duration: Double { player.duration }

    // MARK: - Content (iOS 27 layout)

    private var content: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom
            VStack(spacing: 0) {
                // Top bar — grabber + queue + dismiss
                HStack {
                    Spacer()
                    Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 4.5)
                    Spacer()
                }
                .padding(.top, safeTop + 6)
                .padding(.bottom, 12)

                // Artwork — large, centered, with bass pulse
                artwork
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.horizontal, 48)

                Spacer(minLength: 0)

                // Track info
                trackInfo
                    .padding(.horizontal, 32)

                // Scrubber
                scrubber
                    .padding(.horizontal, 24)

                // Controls — no buttons, just tap areas with icons
                controls
                    .padding(.horizontal, 28)
                    .padding(.bottom, safeBottom > 20 ? safeBottom : 16)

                // Spectrum at bottom
                if player.isPlaying {
                    SpectrumView(barWidth: 4, maxHeight: 36)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
    }

    // MARK: - Artwork

    private var artwork: some View {
        let bass = analyzer.bass
        return AnimatedArtworkView(palette: currentPalette)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: (currentPalette.first ?? Color.teal).opacity(0.55), radius: 50, x: 0, y: 30)
            .scaleEffect(1 + Double(bass) * 0.04)
            .animation(.easeOut(duration: 0.12), value: analyzer.bass)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(spacing: 8) {
            Text(player.currentTrack?.title ?? "Ничего не играет")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(player.currentTrack?.artist ?? "")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.vertical, 10)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        VStack(spacing: 7) {
            GeometryReader { geo in
                let w = geo.size.width
                let val = scrubValue ?? player.progress
                let frac = duration > 0 ? min(max(val / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                    Capsule()
                        .fill(SettingsStore.shared.accentGradient)
                        .frame(width: max(4, w * frac), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .white.opacity(0.3), radius: 4)
                        .offset(x: min(max(0, w * frac - 7.5), w - 15))
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        scrubValue = max(0, min(1, v.location.x / max(w, 1))) * duration
                    }
                    .onEnded { _ in
                        if let s = scrubValue { player.seek(to: s); scrubValue = nil }
                    }
                )
            }
            .frame(height: 18)
            HStack {
                Text(player.formatted(scrubValue ?? player.progress))
                Spacer()
                Text("-" + player.formatted(duration - (scrubValue ?? player.progress)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Controls (gesture-based, no visible buttons)

    private var controls: some View {
        HStack(spacing: 0) {
            // Shuffle — small icon area
            controlArea(width: 44) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: player.shuffle ? .bold : .regular))
                    .foregroundStyle(player.shuffle ? SettingsStore.shared.accentColor : .white.opacity(0.65))
            }

            Spacer()

            // Previous
            controlArea(width: 52) { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            // Play/Pause — large glass circle
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle()
                        .fill(SettingsStore.shared.accentGradient)
                        .frame(width: 72, height: 72)
                        .shadow(color: SettingsStore.shared.accent.main.opacity(0.45), radius: 20, x: 0, y: 8)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Next
            controlArea(width: 52) { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            // Repeat
            controlArea(width: 44) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                player.repeatMode = RepeatMode(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
            } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 17, weight: player.repeatMode != .off ? .bold : .regular))
                    .foregroundStyle(player.repeatMode != .off ? SettingsStore.shared.accentColor : .white.opacity(0.65))
            }
        }
        .padding(.vertical, 14)
    }

    /// Invisible tap area that provides haptic feedback
    private func controlArea<Content: View>(width: CGFloat, action: @escaping () -> Void, @ViewBuilder label: () -> Content) -> some View {
        Button(action: action) {
            label()
                .frame(width: width, height: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                if abs(v.translation.height) > abs(v.translation.width) {
                    dragOffset = CGSize(width: 0, height: max(0, v.translation.height))
                }
            }
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                dragOffset = .zero
                if dy > 100 && abs(dy) > abs(dx) { dismiss() }
                else if dx < -60 { player.next() } else if dx > 60 { player.previous() }
            }
    }
}

// MARK: - Queue sheet

struct QueueSheet: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(player.queue) { track in
                        Button { player.play(track) } label: {
                            HStack(spacing: 12) {
                                SmallArtwork(palette: track.palette, size: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading) {
                                    Text(track.title).lineLimit(1).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if player.currentTrack?.id == track.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(SettingsStore.shared.accentColor)
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 80)
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
