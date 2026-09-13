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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsedTime = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))

            GeometryReader { proxy in
                let w = Float(proxy.size.width)
                let h = Float(proxy.size.height)

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
                    ZStack {
                        // 1. Мягкая фоновая аура (Ambient Glow)
                        Rectangle()
                            .colorEffect(
                                ShaderLibrary.fluidAuraWave(
                                    .float4(0, 0, w, h),
                                    .float(elapsedTime),
                                    .float(bass),
                                    .float(mids),
                                    .float(highs),
                                    .color(c1),
                                    .color(c2),
                                    .color(c3)
                                )
                            )
                            .blur(radius: isBackgroundMode ? 36 : 18)
                            .opacity(0.65)
                            .blendMode(.plusLighter)

                        // 2. Четкое сияющее ядро с HDR-лучами и спекулярными бликами
                        Rectangle()
                            .colorEffect(
                                ShaderLibrary.fluidAuraWave(
                                    .float4(0, 0, w, h),
                                    .float(elapsedTime),
                                    .float(bass),
                                    .float(mids),
                                    .float(highs),
                                    .color(c1),
                                    .color(c2),
                                    .color(c3)
                                )
                            )
                            .blur(radius: isBackgroundMode ? 32 : 12)
                            .opacity(isBackgroundMode ? 0.70 : 0.95)
                    }
                    .scaleEffect(bassPulse * touchScale)
                    .animation(AG.fastSpring, value: bass)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
