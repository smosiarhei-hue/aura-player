import SwiftUI

// MARK: - Fluid Aura Wave (Organic SDF Morphing & Chromatic Dispersion Visualizer)
// Музыкально-чувствительная волна с HDR Glow бликами, каустикой и хроматической дисперсией

struct FluidWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var analyzer = SpectrumAnalyzer.shared

    let colors: [Color]
    var bassIntensity: Float?
    var midIntensity: Float?
    var highIntensity: Float?
    var isBackgroundMode: Bool
    var isPlaying: Bool

    @State private var touchScale: CGFloat = 1.0

    init(
        colors: [Color] = [.pink, .orange, .yellow],
        bass: Float? = nil,
        mid: Float? = nil,
        high: Float? = nil,
        isBackgroundMode: Bool = false,
        isPlaying: Bool = true
    ) {
        self.colors = colors
        self.bassIntensity = bass
        self.midIntensity = mid
        self.highIntensity = high
        self.isBackgroundMode = isBackgroundMode
        self.isPlaying = isPlaying
    }

    private var effectiveBass: Float {
        bassIntensity ?? max(analyzer.bass, analyzer.streamLevel * 0.95)
    }

    private var effectiveMids: Float {
        midIntensity ?? max(analyzer.mids, analyzer.streamLevel * 0.70)
    }

    private var effectiveHighs: Float {
        highIntensity ?? max(analyzer.highs, analyzer.streamLevel * 0.50)
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isPlaying)) { timeline in
            let elapsedTime = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))

            GeometryReader { proxy in
                let c1 = colors.indices.contains(0) ? colors[0] : AG.flame
                let c2 = colors.indices.contains(1) ? colors[1] : AG.ember
                let c3 = colors.indices.contains(2) ? colors[2] : AG.amber

                let bass = isPlaying ? effectiveBass : 0
                let mids = isPlaying ? effectiveMids : 0
                let highs = isPlaying ? effectiveHighs : 0
                let bassPulse = 1.0 + CGFloat(bass) * 0.14

                if reduceMotion {
                    // Fallback for accessibility reduce motion
                    ZStack {
                        RadialGradient(
                            colors: [c1.opacity(0.85), c2.opacity(0.40), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: min(proxy.size.width, proxy.size.height) * 0.45
                        )
                    }
                } else {
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let baseRadius = min(size.width, size.height) * 0.24
                        let pulse = 1 + CGFloat(bass) * 0.16
                        let drift = CGFloat(sin(elapsedTime * 0.8)) * size.width * 0.06
                        let layers: [(Color, CGFloat, CGFloat)] = [
                            (c1, 1.55, drift),
                            (c2, 1.20, -drift * 0.7),
                            (c3, 0.88, drift * 0.45)
                        ]

                        for (index, layer) in layers.enumerated() {
                            let phase = elapsedTime * (0.45 + Float(index) * 0.12)
                            let offset = CGPoint(
                                x: layer.2 + CGFloat(cos(phase)) * size.width * 0.08,
                                y: CGFloat(sin(phase * 1.17)) * size.height * 0.08
                            )
                            let radius = baseRadius * layer.1 * pulse
                            let rect = CGRect(
                                x: center.x + offset.x - radius,
                                y: center.y + offset.y - radius,
                                width: radius * 2,
                                height: radius * 2
                            )
                            context.fill(
                                Path(ellipseIn: rect),
                                with: .radialGradient(
                                    Gradient(colors: [layer.0.opacity(0.92), layer.0.opacity(0)]),
                                    center: CGPoint(x: rect.midX, y: rect.midY),
                                    startRadius: 0,
                                    endRadius: radius
                                )
                            )
                        }
                    }
                    .blur(radius: isBackgroundMode ? 24 : 14)
                    .opacity(0.82 + Double(highs) * 0.12)
                    .blendMode(.plusLighter)
                    .scaleEffect(bassPulse * touchScale)
                    .animation(AG.fastSpring, value: bass)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
