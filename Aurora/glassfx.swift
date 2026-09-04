import SwiftUI

// MARK: - Motion primitives
//
// Press feedback and section entrance. Glass, glow and shimmer are the
// system's job now (see theme.swift), so this file only owns how things move.

/// Spring compression for controls that sit on glass.
struct GlassPressStyle: ButtonStyle {
    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(AG.fastSpring, value: configuration.isPressed)
    }
}

/// Card / row press with a light haptic on touch-down.
struct CardPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(AG.fastSpring, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && haptic {
                    Haptics.tap(.light)
                }
            }
    }
}

/// Now-playing indicator: three bars that breathe while audio plays.
struct LiveWaveEqualizer: View {
    let isPlaying: Bool
    var color: Color = AG.amber
    var barCount: Int = 3

    @State private var wavePhases: [CGFloat] = [0.4, 0.9, 0.6]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 2.5, height: isPlaying ? 12 * wavePhases[i % wavePhases.count] : 3)
            }
        }
        .frame(width: 14, height: 14, alignment: .bottom)
        .onAppear { animateIfNeeded() }
        .onChange(of: isPlaying) { _, _ in animateIfNeeded() }
    }

    private func animateIfNeeded() {
        guard isPlaying else { return }
        withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
            wavePhases = [0.95, 0.35, 0.8]
        }
    }
}

/// Section entrance: a short rise with fade, staggered by `delay`.
struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                withAnimation(AG.spring.delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0) -> some View {
        modifier(RiseIn(delay: delay))
    }
}
