import SwiftUI
import UIKit

/// A fullscreen ray field, behind all home content rather than around the artwork.
struct PrismaticBurstBackground: View {
    let colors: [Color]
    let isPlaying: Bool
    let isVisible: Bool
    @State private var analyzer = SpectrumAnalyzer.shared
    @State private var isOnScreen = false
    @State private var time: Float = 0
    @State private var previousFrame: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var running: Bool { isOnScreen && isPlaying && isVisible && !reduceMotion && scenePhase == .active }
    private var interval: Double { ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 / 20.0 : 1 / 30.0 }
    private var palette: [Color] {
        colors.isEmpty ? [.pink, .purple, .cyan] : colors
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !running)) { timeline in
            GeometryReader { proxy in
                let fresh = running && Date.timeIntervalSinceReferenceDate - analyzer.lastAudioSampleTime < 0.4
                let kick = fresh ? analyzer.kick : 0
                let bass = fresh ? analyzer.bass : 0
                let mids = fresh ? analyzer.mids : 0
                // Lower-resolution GPU rendering avoids 44-step ray marching at full
                // Retina resolution; upscaling keeps this background smooth and bounded.
                Color.white
                    .frame(width: max(1, proxy.size.width * 0.5), height: max(1, proxy.size.height * 0.5))
                    .visualEffect { content, _ in
                        content.colorEffect(ShaderLibrary.prismaticBurst(
                            .boundingRect, .float(reduceMotion ? 3 : time),
                            .float(kick), .float(bass), .float(mids),
                            .color(palette[0]), .color(palette[min(1, palette.count - 1)]),
                            .color(palette[min(2, palette.count - 1)])
                        ))
                    }
                    .drawingGroup(opaque: true)
                    .scaleEffect(2)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .onChange(of: timeline.date) { _, date in
                guard running else { previousFrame = nil; return }
                let now = date.timeIntervalSinceReferenceDate
                if let previousFrame { time += Float(min(0.10, max(0, now - previousFrame))) }
                previousFrame = now
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: running) { _, _ in previousFrame = nil }
        .onAppear { isOnScreen = true; previousFrame = nil }
        .onDisappear { isOnScreen = false; previousFrame = nil }
    }
}
