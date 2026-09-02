import SwiftUI

// MARK: - AutoMix visual hand-off
//
// A real cover-to-cover "show": the incoming track's artwork rises from
// underneath the outgoing one while an HDR-style specular "blik" sweeps
// diagonally across the whole stage in sync with the actual DSP blend
// progress (dj.transitionProgress), not a fixed-length animation of its own.
// Mounted directly over the artwork stage, so it can never cover the
// transport controls or the timeline below it.

struct AutoMixTransitionOverlay: View {
    @State private var player = PlayerCore.shared
    @State private var dj = AutoMixDJEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches the square side of the artwork stage this overlay sits on top of.
    let side: CGFloat

    private var outgoingPalette: [Color] {
        let values = player.currentTrack?.palette ?? []
        return values.isEmpty ? [AG.amber, AG.ember] : values
    }

    /// Best-effort look-ahead at the track AutoMix is blending toward. Mirrors
    /// PlayerCore's own queue-index lookup (shuffle already committed to a pick
    /// internally before the blend starts, but that pick is not exposed - the
    /// visual falls back to the light sweep alone when no artwork can be found).
    private var incomingTrack: Track? {
        let q = player.queue
        guard let cur = player.currentTrack, let idx = q.firstIndex(where: { $0.id == cur.id }) else {
            return q.first
        }
        let nextIdx = idx + 1
        if nextIdx < q.count { return q[nextIdx] }
        return q.count > 1 ? q.first : nil
    }

    private var incomingImage: UIImage? {
        guard let incomingTrack else { return nil }
        return LibraryStore.cachedArtworkImage(for: incomingTrack)
    }

    var body: some View {
        if dj.isTransitionActive {
            let progress = min(1, max(0, dj.transitionProgress))
            ZStack {
                // The incoming cover rises underneath the outgoing artwork as the
                // blend advances, so the hand-off actually reads as cover-to-cover.
                if let incomingImage {
                    Image(uiImage: incomingImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .opacity(progress)
                        .scaleEffect(0.97 + 0.03 * progress)
                }

                // HDR "blik": a bright diagonal band travels corner-to-corner across
                // the stage over the course of the whole blend, brightened with
                // .plusLighter so it reads as a light sweep, not a flat wash.
                if !reduceMotion {
                    GeometryReader { proxy in
                        let diagonal = proxy.size.width + proxy.size.height
                        let band = max(proxy.size.width, proxy.size.height) * 0.5
                        let travel = diagonal + band * 2
                        let sweep = CGFloat(progress) * travel - band

                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white.opacity(0.55), location: 0.40),
                                .init(color: .white.opacity(0.95), location: 0.5),
                                .init(color: .white.opacity(0.55), location: 0.60),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: band, height: proxy.size.height * 2.4)
                        .rotationEffect(.degrees(32))
                        .offset(x: sweep - proxy.size.width * 0.5)
                        .blendMode(.plusLighter)
                    }
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .opacity(sweepIntensity(progress))
                    .allowsHitTesting(false)
                }

                // A soft HDR bloom peaking mid-mix, so the hand-off feels like a
                // brief show rather than an abrupt cut - independent of whether an
                // incoming cover image could be resolved.
                RadialGradient(
                    colors: [
                        .white.opacity(bloomIntensity(progress) * 0.34),
                        (outgoingPalette.first ?? AG.amber).opacity(bloomIntensity(progress) * 0.22),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: side * 0.75
                )
                .blendMode(.screen)
                .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func sweepIntensity(_ progress: Double) -> Double {
        // Full brightness through the body of the mix, easing in/out at the
        // very start and end so the sweep never pops.
        if progress < 0.08 { return progress / 0.08 }
        if progress > 0.92 { return (1 - progress) / 0.08 }
        return 1
    }

    private func bloomIntensity(_ progress: Double) -> Double {
        let distance = abs(progress - 0.5) / 0.22
        return max(0, 1 - distance * distance)
    }
}
