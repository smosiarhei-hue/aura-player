import SwiftUI

// MARK: - AutoMix visual hand-off
// A restrained glow/flash only. The AutoMix label stays in the dedicated slot
// below the timeline, so this overlay can never cover transport controls.

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
                let flash = flashIntensity(progress)
                let accent = palette.first ?? AG.amber
                let companion = palette.dropFirst().first ?? AG.ember

                ZStack {
                    RadialGradient(
                        colors: [accent.opacity(0.18), companion.opacity(0.10 * progress), .clear],
                        center: .center,
                        startRadius: 12,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                    )
                    .blendMode(.plusLighter)

                    RadialGradient(
                        colors: [.white.opacity(flash * 0.38), accent.opacity(flash * 0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * (0.18 + flash * 0.24)
                    )
                    .blendMode(.screen)
                    .opacity(reduceMotion ? flash * 0.25 : flash)
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
        }
    }

    private func flashIntensity(_ progress: Double) -> Double {
        let distance = abs(progress - 0.5) / 0.15
        return max(0, 1 - distance * distance)
    }
}
