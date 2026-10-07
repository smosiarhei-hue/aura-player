import SwiftUI
import UIKit

/// Continuous phase plus attack/release envelopes: music changes speed, never jumps time.
nonisolated struct MusicWaveMotion {
    private(set) var phase: Float = 0
    private(set) var energy: Float = 0
    private(set) var impact: Float = 0
    private(set) var detail: Float = 0
    private(set) var speed: Float = 0

    mutating func advance(delta: Float, bass: Float, mids: Float, highs: Float,
                          level: Float, kick: Float, hasFreshAudio: Bool) {
        let dt = delta.isFinite ? max(0, min(0.1, delta)) : 0
        func unit(_ value: Float) -> Float { value.isFinite ? max(0, min(1, value)) : 0 }
        let targetEnergy = hasFreshAudio
            ? unit(bass) * 0.42 + unit(mids) * 0.30 + unit(level) * 0.28 : 0
        let targetImpact = hasFreshAudio ? unit(kick) : 0
        let targetDetail = hasFreshAudio ? unit(highs) * 0.55 + unit(mids) * 0.45 : 0
        energy += (targetEnergy - energy) * (1 - exp(-dt / (targetEnergy > energy ? 0.10 : 0.42)))
        impact += (targetImpact - impact) * (1 - exp(-dt / (targetImpact > impact ? 0.035 : 0.22)))
        detail += (targetDetail - detail) * (1 - exp(-dt / 0.24))
        // Fast passages flow faster; quiet passages settle. No guessed BPM or metronome.
        let targetSpeed: Float = hasFreshAudio && targetEnergy > 0.003
            ? 0.14 + energy * 1.65 + impact * 0.70 : 0
        speed += (targetSpeed - speed) * (1 - exp(-dt / (targetSpeed > speed ? 0.12 : 0.48)))
        phase += dt * speed
    }

    mutating func settle() {
        energy = 0; impact = 0; detail = 0; speed = 0
    }
}

/// Soft flowing ribbons, confined to the wave hero and dissolving into the current theme.
struct MusicWaveBackground: View {
    let colors: [Color]
    let isPlaying: Bool
    let isVisible: Bool
    @State private var analyzer = SpectrumAnalyzer.shared
    @State private var isOnScreen = false
    @State private var motion = MusicWaveMotion()
    @State private var previousFrame: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var running: Bool { isOnScreen && isPlaying && isVisible && !reduceMotion && scenePhase == .active }
    private var interval: Double { ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 / 20.0 : 1 / 30.0 }
    private var palette: [Color] { colors.isEmpty ? [.pink, .purple, .cyan] : colors }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !running)) { timeline in
            GeometryReader { proxy in
                let shaderColors = palette
                let phase = motion.phase
                let energy = motion.energy
                let impact = motion.impact
                let detail = motion.detail
                let darkMode: Float = colorScheme == .dark ? 1 : 0
                Color.white
                    .frame(width: max(1, proxy.size.width * 0.5), height: max(1, proxy.size.height * 0.5))
                    .visualEffect { content, _ in
                        content.colorEffect(ShaderLibrary.musicWaveRibbons(
                            .boundingRect, .float(phase),
                            .float(energy), .float(impact), .float(detail),
                            .float(darkMode),
                            .color(shaderColors[0]), .color(shaderColors[min(1, shaderColors.count - 1)]),
                            .color(shaderColors[min(2, shaderColors.count - 1)])
                        ))
                    }
                    .drawingGroup(opaque: false)
                    .scaleEffect(2)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .onChange(of: timeline.date) { _, date in
                guard running else { previousFrame = nil; return }
                let now = date.timeIntervalSinceReferenceDate
                let delta = Float(min(0.10, max(0, now - (previousFrame ?? now))))
                previousFrame = now
                let fresh = Date.timeIntervalSinceReferenceDate - analyzer.lastAudioSampleTime < 0.4
                motion.advance(delta: delta, bass: analyzer.bass, mids: analyzer.mids,
                               highs: analyzer.highs, level: analyzer.level, kick: analyzer.kick,
                               hasFreshAudio: fresh)
            }
        }
        // Blur only the decorative layer, never artwork, text, or touch targets.
        .blur(radius: 5)
        .mask {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.white)
                .blur(radius: 24)
                .padding(12)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: running) { _, active in
            previousFrame = nil
            if !active { motion.settle() }
        }
        .onAppear { isOnScreen = true; previousFrame = nil }
        .onDisappear { isOnScreen = false; previousFrame = nil; motion.settle() }
    }
}
