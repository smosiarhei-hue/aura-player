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
        }
        .statusBarHidden()
        .colorScheme(.dark)
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    private var currentPalette: [Color] { player.currentTrack?.palette ?? Palette.seeded(42).colors }
    private var duration: Double { player.duration }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 18) {
            header
            Spacer(minLength: 0)
            artwork
            Spacer(minLength: 0)
            trackInfo
            scrubber
            controls
            bottomRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .offset(y: max(0, dragOffset.height))
        .opacity(1 - min(0.5, Double(dragOffset.height / 400)))
        .gesture(dragGesture)
    }

    // MARK: - Header (grabber + queue)

    private var header: some View {
        VStack(spacing: 10) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 42, height: 5)
            HStack {
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .glassCard(corner: 19)
                }
            }
        }
    }

    // MARK: - Artwork with beat pulse

    private var artwork: some View {
        let bass = analyzer.bass
        return AnimatedArtworkView(palette: currentPalette)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: (currentPalette.first ?? Color.teal).opacity(0.5), radius: 40, x: 0, y: 24)
            .scaleEffect(1 + Double(bass) * 0.045)
            .animation(.easeOut(duration: 0.14), value: analyzer.bass)
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(spacing: 6) {
            Text(player.currentTrack?.title ?? "Ничего не играет")
                .font(.title2.weight(.bold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.center)
            Text(player.currentTrack?.artist ?? "")
                .font(.subheadline).foregroundStyle(.white.opacity(0.65))
        }
    }

    // MARK: - Scrubber (custom progress slider)

    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let val = scrubValue ?? player.progress
                let frac = duration > 0 ? min(max(val / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                    Capsule()
                        .fill(LinearGradient(colors: SettingsStore.shared.accent.colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, w * frac), height: 5)
                    Circle()
                        .fill(.white).frame(width: 14, height: 14).shadow(radius: 3)
                        .offset(x: min(max(0, w * frac - 7), w - 14))
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrubValue = max(0, min(1, v.location.x / max(w, 1))) * duration }
                    .onEnded { _ in if let s = scrubValue { player.seek(to: s); scrubValue = nil } })
            }
            .frame(height: 16)
            HStack {
                Text(player.formatted(scrubValue ?? player.progress))
                Spacer()
                Text("-" + player.formatted(duration - (scrubValue ?? player.progress)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 0) {
            controlButton(player.shuffle ? "shuffle" : "shuffle", isActive: player.shuffle) { player.shuffle.toggle() }
            Spacer()
            controlButton("backward.fill", size: 26) { player.previous() }
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(
                        LinearGradient(colors: SettingsStore.shared.accent.colors,
                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: SettingsStore.shared.accent.main.opacity(0.45), radius: 18, x: 0, y: 8)
            }.buttonStyle(.plain)
            Spacer()
            controlButton("forward.fill", size: 26) { player.next() }
            Spacer()
            controlButton(player.repeatMode.icon, isActive: player.repeatMode != .off) {
                player.repeatMode = RepeatMode(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
            }
        }
    }

    private func controlButton(_ icon: String, size: CGFloat = 20, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isActive ? SettingsStore.shared.accentColor : .white.opacity(0.85))
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain)
    }

    // MARK: - Bottom spectrum

    private var bottomRow: some View {
        HStack { SpectrumView().frame(maxWidth: .infinity) }.padding(.top, 4)
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
                if dy > 110 && abs(dy) > abs(dx) { dismiss() }
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
            List(player.queue) { track in
                Button { player.play(track) } label: {
                    HStack {
                        SmallArtwork(palette: track.palette, size: 38)
                        VStack(alignment: .leading) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if player.currentTrack?.id == track.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(SettingsStore.shared.accentColor)
                        }
                    }
                }.buttonStyle(.plain)
            }
            .navigationTitle("Очередь").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
