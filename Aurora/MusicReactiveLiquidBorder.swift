import SwiftUI

/// A thin, procedural Liquid Glass outline driven by the audio that is
/// currently leaving the main mixer. It intentionally uses no GIF or bitmap:
/// the contour stays sharp at every artwork size and reacts to the selected
/// track's real bass/mid energy.
struct MusicReactiveLiquidBorder: View {
    let player: ActivePlayerPresentation
    let cornerRadius: CGFloat
    let palette: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spectrum = SpectrumAnalyzer.shared

    var body: some View {
        Group {
            if reduceMotion {
                liquidFrame(date: .distantPast)
            } else {
                TimelineView(.animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: !player.isPlaying
                )) { context in
                    liquidFrame(date: context.date)
                }
            }
        }
        .id(player.displayTrack?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func liquidFrame(date: Date) -> some View {
        let bass = clamped(max(spectrum.bass, spectrum.streamLevel) * 2.1)
        let mids = clamped(max(spectrum.mids, spectrum.streamLevel * 0.65) * 1.7)
        let highs = clamped(spectrum.highs * 1.8)
        let energy = clamped(bass * 0.64 + mids * 0.26 + highs * 0.10)
        let activeEnergy = player.isPlaying ? energy : 0
        let playbackTime = max(0, player.progress)
        let flowTime = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let angle = (playbackTime * 11.0 + flowTime * (12.0 + Double(mids) * 15.0))
            .truncatingRemainder(dividingBy: 360)
        let primary = palette.first ?? Color.cyan
        let secondary = palette.dropFirst().first ?? Color.blue
        let radius = cornerRadius + activeEnergy * 1.8
        let width = 0.78 + activeEnergy * 1.18

        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(player.isPlaying ? 0.13 : 0.09), lineWidth: 0.65)

            liquidStroke(
                radius: radius,
                angle: angle,
                primary: primary,
                secondary: secondary,
                opacity: 0.48 + Double(activeEnergy) * 0.42,
                width: width
            )
            .blur(radius: 5.5 + activeEnergy * 3.0)
            .opacity(0.34 + Double(activeEnergy) * 0.32)

            liquidStroke(
                radius: radius,
                angle: angle,
                primary: primary,
                secondary: secondary,
                opacity: 0.62 + Double(activeEnergy) * 0.34,
                width: width
            )

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .trim(from: 0.06, to: 0.24)
                .stroke(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.62 + Double(bass) * 0.30), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 0.72 + bass * 0.88, lineCap: .round)
                )
                .rotationEffect(.degrees(angle + Double(bass) * 7.0))
                .blur(radius: 0.15)
        }
        .padding(1.5)
        .scaleEffect(1.0 + activeEnergy * 0.0035)
        .animation(.linear(duration: 0.08), value: activeEnergy)
        .compositingGroup()
        .blendMode(.plusLighter)
    }

    private func liquidStroke(
        radius: CGFloat,
        angle: Double,
        primary: Color,
        secondary: Color,
        opacity: Double,
        width: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.18), location: 0.00),
                        .init(color: primary.opacity(0.48), location: 0.18),
                        .init(color: .white.opacity(0.98), location: 0.31),
                        .init(color: secondary.opacity(0.52), location: 0.48),
                        .init(color: .white.opacity(0.16), location: 0.66),
                        .init(color: .white.opacity(0.88), location: 0.83),
                        .init(color: .white.opacity(0.18), location: 1.00)
                    ]),
                    center: .center,
                    startAngle: .degrees(angle),
                    endAngle: .degrees(angle + 360)
                )
                .opacity(opacity),
                lineWidth: width
            )
    }

    private func clamped(_ value: Float) -> CGFloat {
        CGFloat(min(1, max(0, value.isFinite ? value : 0)))
    }
}
