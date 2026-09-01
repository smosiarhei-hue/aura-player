import SwiftUI

// MARK: - Fluid Aura Wave (Organic SDF Morphing & Chromatic Dispersion Visualizer)

struct FluidWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var analyzer = SpectrumAnalyzer.shared

    let colors: [Color]
    var bassIntensity: Float?
    var midIntensity: Float?
    var highIntensity: Float?
    var isBackgroundMode: Bool

    @State private var touchScale: CGFloat = 1.0

    init(
        colors: [Color] = [.pink, .cyan, .yellow],
        bass: Float? = nil,
        mid: Float? = nil,
        high: Float? = nil,
        isBackgroundMode: Bool = false
    ) {
        self.colors = colors
        self.bassIntensity = bass
        self.midIntensity = mid
        self.highIntensity = high
        self.isBackgroundMode = isBackgroundMode
    }

    private var effectiveBass: Float {
        bassIntensity ?? analyzer.bass
    }

    private var effectiveMids: Float {
        midIntensity ?? analyzer.mids
    }

    private var effectiveHighs: Float {
        highIntensity ?? analyzer.highs
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: isBackgroundMode ? 1.0 / 30.0 : 1.0 / 60.0)) { timeline in
            let elapsedTime = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))

            GeometryReader { proxy in
                let w = Float(proxy.size.width)
                let h = Float(proxy.size.height)

                let c1 = colors.indices.contains(0) ? colors[0] : (Color(hex: "#FBBF24") ?? .yellow)
                let c2 = colors.indices.contains(1) ? colors[1] : (Color(hex: "#F97316") ?? .orange)
                let c3 = colors.indices.contains(2) ? colors[2] : (Color(hex: "#FF8AD1") ?? .pink)

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
                    Rectangle()
                        .colorEffect(
                            ShaderLibrary.fluidAuraWave(
                                .float4(0, 0, w, h),
                                .float(elapsedTime),
                                .float(effectiveBass),
                                .float(effectiveMids),
                                .float(effectiveHighs),
                                .color(c1),
                                .color(c2),
                                .color(c3)
                            )
                        )
                        .blur(radius: isBackgroundMode ? 50 : 0)
                        .opacity(isBackgroundMode ? 0.65 : 1.0)
                        .blendMode(isBackgroundMode ? .plusLighter : .normal)
                        .scaleEffect(touchScale)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
