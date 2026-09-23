import SwiftUI

/// Thin vector outline driven by the main mixer's live frequency energy.
/// The border belongs to the committed audible track, not the incoming deck.
struct MusicReactiveLiquidBorder: View {
    let player: ActivePlayerPresentation
    let cornerRadius: CGFloat
    let palette: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spectrum = SpectrumAnalyzer.shared

    var body: some View {
        Group {
            if reduceMotion || !player.isPlaying {
                frame(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    frame(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .id(player.displayTrack?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frame(at clock: TimeInterval) -> some View {
        let bass = CGFloat(min(1, max(0, max(spectrum.bass, spectrum.streamLevel) * 2.1)))
        let mids = CGFloat(min(1, max(0, max(spectrum.mids, spectrum.streamLevel * 0.65) * 1.7)))
        let energy = player.isPlaying ? min(1, bass * 0.72 + mids * 0.28) : 0
        let primary = palette.first ?? .cyan
        let secondary = palette.dropFirst().first ?? .blue
        let angle = player.progress * 10 + clock * (11 + Double(mids) * 12)
        let gradient = AngularGradient(
            gradient: Gradient(colors: [
                .white.opacity(0.18),
                primary.opacity(0.52),
                .white.opacity(0.96),
                secondary.opacity(0.48),
                .white.opacity(0.14),
                .white.opacity(0.82),
                .white.opacity(0.18)
            ]),
            center: .center,
            startAngle: .degrees(angle),
            endAngle: .degrees(angle + 360)
        )
        let lineWidth: CGFloat = 0.8 + energy * 1.05
        let glowOpacity = 0.24 + Double(energy) * 0.34

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(player.isPlaying ? 0.12 : 0.08), lineWidth: 0.65)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(gradient, lineWidth: lineWidth)
                .blur(radius: 5 + energy * 2.5)
                .opacity(glowOpacity)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(gradient, lineWidth: lineWidth)
                .opacity(0.68 + Double(energy) * 0.28)
        }
        .padding(1.5)
        .scaleEffect(1 + energy * 0.003)
        .animation(.linear(duration: 0.08), value: energy)
        .compositingGroup()
        .blendMode(.plusLighter)
    }
}
