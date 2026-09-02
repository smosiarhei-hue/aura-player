import SwiftUI

// MARK: - AutoMix visual hand-off
//
// A deliberately small, temporary visual cue for the actual DJ hand-off. It is
// not a permanent animated background: it exists only while PlayerCore reports a
// live transition, reads the already-published progress, and respects Reduce
// Motion. This keeps the transition visible without competing with the cover art
// or spending battery while the player is idle.

struct AutoMixTransitionOverlay: View {
    @State private var player = PlayerCore.shared
    @State private var dj = AutoMixDJEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: [Color] {
        let values = player.currentTrack?.palette ?? []
        return values.isEmpty ? [AG.amber, AG.ember] : values
    }

    var body: some View {
        if dj.isTransitionActive {
            GeometryReader { proxy in
                let progress = min(1, max(0, dj.transitionProgress))
                let handOff = flashIntensity(progress)
                let accent = palette.first ?? AG.amber
                let companion = palette.dropFirst().first ?? AG.ember

                ZStack {
                    // A low-opacity colour halo makes the changing energy visible
                    // without covering the song information or faking a glass card.
                    RadialGradient(
                        colors: [accent.opacity(0.28 * (1 - progress)), companion.opacity(0.11), .clear],
                        center: .center,
                        startRadius: 8,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.68
                    )
                    .blendMode(.plusLighter)

                    // A short light bloom marks the exact middle of the hand-off.
                    // It is derived from transition progress, not repeatForever.
                    RadialGradient(
                        colors: [.white.opacity(handOff * 0.52), accent.opacity(handOff * 0.24), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * (0.24 + handOff * 0.28)
                    )
                    .blendMode(.screen)
                    .opacity(reduceMotion ? handOff * 0.42 : handOff)

                    VStack {
                        Spacer()
                        HStack(spacing: 7) {
                            Image(systemName: "waveform.path.ecg")
                                .symbolRenderingMode(.hierarchical)
                            Text("AutoMix")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .glassEffect(.regular, in: .capsule)
                        .opacity(reduceMotion ? 0.72 : 0.58 + handOff * 0.34)
                        .padding(.bottom, proxy.safeAreaInsets.bottom + 104)
                    }
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.20), value: dj.isTransitionActive)
            }
        }
    }

    private func flashIntensity(_ progress: Double) -> Double {
        // Bell curve centered at the musical hand-off point (50%).
        let distance = abs(progress - 0.5) / 0.15
        return max(0, 1 - distance * distance)
    }
}
