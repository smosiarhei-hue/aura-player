import SwiftUI
import UIKit

/// Non-rotating fluid field inspired by the My Wave reference.
/// Slow organic drift is combined with kick and 30...120 Hz bass energy.
struct FluidWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visuals.hdr.enabled") private var hdrEnabled = true
    @AppStorage("visuals.waveBeat.enabled") private var beatEnabled = true
    @State private var analyzer = SpectrumAnalyzer.shared

    let colors: [Color]
    var bassIntensity: Float?
    var midIntensity: Float?
    var highIntensity: Float?
    var isBackgroundMode: Bool
    var isPlaying: Bool

    init(colors: [Color] = [.pink, .purple, .orange], bass: Float? = nil,
         mid: Float? = nil, high: Float? = nil,
         isBackgroundMode: Bool = false, isPlaying: Bool = true) {
        self.colors = colors
        bassIntensity = bass
        midIntensity = mid
        highIntensity = high
        self.isBackgroundMode = isBackgroundMode
        self.isPlaying = isPlaying
    }

    private var interval: TimeInterval {
        1 / Double(max(UIScreen.main.maximumFramesPerSecond, 60))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval,
                                paused: reduceMotion || !isPlaying)) { timeline in
            GeometryReader { proxy in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let kick = isPlaying && beatEnabled ? Double(analyzer.kick) : 0
                let bass = isPlaying && beatEnabled
                    ? Double(bassIntensity ?? analyzer.bass) : 0
                let energy = min(1, max(kick, bass * 0.72))
                fluidLayer(size: proxy.size, time: time, energy: energy)
            }
        }
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fluidLayer(size: CGSize, time: TimeInterval,
                            energy: Double) -> some View {
        let unit = min(size.width, size.height)
        let pulse = 1 + CGFloat(energy) * 0.095
        return ZStack {
            ForEach(0..<5, id: \.self) { index in
                let point = blobPoint(index: index, time: time, size: size)
                let diameter = unit * blobScale(index) * pulse
                Circle()
                    .fill(RadialGradient(
                        colors: [palette[index].opacity(0.98),
                                 palette[index].opacity(0.58), .clear],
                        center: .center, startRadius: 0, endRadius: diameter * 0.52))
                    .frame(width: diameter, height: diameter * 0.82)
                    .position(point)
            }

            if hdrEnabled {
                ForEach(0..<4, id: \.self) { index in
                    let point = highlightPoint(index: index, time: time, size: size)
                    let diameter = unit * (0.22 + CGFloat(index) * 0.012) *
                        (1 + CGFloat(energy) * 0.22)
                    Circle()
                        .fill(RadialGradient(
                            colors: [
                                palette[index]
                                    .exposureAdjust(1.2 + energy * 1.35)
                                    .headroom(2.2 + energy * 2.8)
                                    .opacity(0.25 + energy * 0.62),
                                palette[index].opacity(0.08 + energy * 0.22),
                                .clear
                            ], center: .center, startRadius: 0,
                            endRadius: diameter * 0.52))
                        .frame(width: diameter, height: diameter)
                        .position(point)
                        .blendMode(.plusLighter)
                }
                .blur(radius: 7 + CGFloat(energy) * 10)
            }
        }
        .blur(radius: isBackgroundMode ? 30 : 16)
        .scaleEffect(pulse)
        .opacity(0.97)
        .animation(.linear(duration: 0.045), value: energy)
    }

    private func blobPoint(index: Int, time: TimeInterval,
                           size: CGSize) -> CGPoint {
        let anchors: [(CGFloat, CGFloat)] = [
            (0.30, 0.34), (0.68, 0.36), (0.36, 0.65),
            (0.72, 0.66), (0.51, 0.76)
        ]
        let anchor = anchors[index]
        let speed = 0.20 + Double(index) * 0.035
        return CGPoint(
            x: size.width * anchor.0 + sin(time * speed + Double(index)) * size.width * 0.075,
            y: size.height * anchor.1 + cos(time * speed * 0.84 + Double(index)) * size.height * 0.065
        )
    }

    private func highlightPoint(index: Int, time: TimeInterval,
                                size: CGSize) -> CGPoint {
        let anchors: [(CGFloat, CGFloat)] = [
            (0.40, 0.40), (0.61, 0.47), (0.47, 0.62), (0.69, 0.64)
        ]
        let anchor = anchors[index]
        return CGPoint(
            x: size.width * anchor.0 + sin(time * (0.29 + Double(index) * 0.03)) * size.width * 0.045,
            y: size.height * anchor.1 + cos(time * (0.25 + Double(index) * 0.025)) * size.height * 0.038
        )
    }

    private func blobScale(_ index: Int) -> CGFloat {
        [0.92, 0.84, 0.96, 0.78, 0.70][index]
    }

    private var palette: [Color] {
        let fallback: [Color] = [
            Color(red: 1.0, green: 0.04, blue: 0.72),
            Color(red: 0.55, green: 0.12, blue: 1.0),
            Color(red: 1.0, green: 0.12, blue: 0.10),
            Color(red: 1.0, green: 0.57, blue: 0.04),
            Color(red: 0.15, green: 0.78, blue: 1.0)
        ]
        return Array((colors + fallback).prefix(5))
    }
}
