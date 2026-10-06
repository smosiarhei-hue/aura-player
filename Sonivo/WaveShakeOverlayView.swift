import SwiftUI
import CoreHaptics
import QuartzCore

/// One physical envelope drives both ring expansion and Taptic intensity.
/// The legacy filename is kept for source compatibility; the liquid sweep is gone.
enum ShaderImpulseTimeline {
    static let duration: TimeInterval = 2.6
    static let onsets: [TimeInterval] = [0.08, 0.60, 1.12, 1.64]
    static let strengths: [Float] = [0.85, 0.68, 0.52, 0.38]
    static let pulseDuration: TimeInterval = 0.46

    static func pulse(_ age: TimeInterval) -> Float {
        guard age >= 0, age < pulseDuration else { return 0 }
        // Gentle compression, physical impulse, then damped relaxation.
        if age < 0.09 { return Float(age / 0.09) }
        let release = (age - 0.09) / (pulseDuration - 0.09)
        return Float(exp(-4.0 * release) * (1 - release))
    }

    static func envelope(at elapsed: TimeInterval) -> Float {
        zip(onsets, strengths).reduce(Float(0)) { value, pair in
            max(value, pulse(elapsed - pair.0) * pair.1)
        }
    }

    static func visibility(at elapsed: TimeInterval) -> Double {
        min(1, max(0, elapsed / 0.12)) * min(1, max(0, (duration - elapsed) / 0.40))
    }
}

@MainActor
final class ShaderPhysicsHaptics {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var ownsVisualOverride = false

    /// Schedule haptics and return the matching monotonic visual epoch.
    func play(reduceMotion: Bool) -> TimeInterval {
        stop()
        guard !reduceMotion, SettingsStore.shared.hapticsEnabled,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return CACurrentMediaTime()
        }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.stop() }
            }
            try engine.start()
            self.engine = engine
            let scale: Float
            switch SettingsStore.shared.musicHapticsIntensity {
            case .soft: scale = 0.45
            case .medium: scale = 0.75
            case .strong: scale = 1
            }
            let events = ShaderImpulseTimeline.onsets.map { onset in
                CHHapticEvent(eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.24)
                    ], relativeTime: onset, duration: ShaderImpulseTimeline.pulseDuration)
            }
            // Keep each curve below CoreHaptics' 16-point limit. The same sampled
            // compression/release envelope drives the shader on every display frame.
            let curves = zip(ShaderImpulseTimeline.onsets, ShaderImpulseTimeline.strengths).map { onset, strength in
                let ages: [TimeInterval] = [0, 0.025, 0.05, 0.075, 0.09, 0.12, 0.16, 0.20, 0.25, 0.30, 0.36, 0.42, 0.46]
                let points = ages.map { age in
                    return CHHapticParameterCurve.ControlPoint(relativeTime: age,
                        value: ShaderImpulseTimeline.pulse(age) * strength * scale)
                }
                return CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                               controlPoints: points, relativeTime: onset)
            }
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            self.player = player
            MusicHapticsManager.core.setVisualOverride(true)
            ownsVisualOverride = true
            let epoch = CACurrentMediaTime() + 0.035
            try player.start(atTime: engine.currentTime + 0.035)
            return epoch
        } catch {
            stop()
            // Visuals continue on unsupported or temporarily unavailable hardware.
            return CACurrentMediaTime()
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        if ownsVisualOverride {
            MusicHapticsManager.core.setVisualOverride(false)
            ownsVisualOverride = false
        }
    }
}

struct ShaderShakeOverlayView: View {
    let isActive: Bool
    let triggerCount: Int
    let palette: [Color]
    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var epoch: TimeInterval = 0
    @State private var haptics = ShaderPhysicsHaptics()

    private var interval: TimeInterval {
        1 / Double(min(120, max(60, UIScreen.main.maximumFramesPerSecond)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isActive && scenePhase == .active {
                if reduceMotion {
                    // Static alternative: no flashing rings or vibration.
                    Color.clear
                } else {
                    TimelineView(.animation(minimumInterval: interval, paused: !isActive)) { _ in
                        let elapsed = max(0, CACurrentMediaTime() - epoch)
                        let impulse = ShaderImpulseTimeline.envelope(at: elapsed)
                        Color.white
                            .visualEffect { content, _ in
                                content.colorEffect(ShaderLibrary.radialShaderAnimation(
                                    .boundingRect, .float(Float(elapsed)), .float(impulse)
                                ))
                            }
                            // Screen blending only adds light; it cannot darken content below.
                            .blendMode(.screen)
                            .opacity(ShaderImpulseTimeline.visibility(at: elapsed) * 0.94)
                    }
                }
                VStack(spacing: 3) {
                    Text(title).font(SN.text(.subheadline, .bold))
                    Text(subtitle).font(SN.text(.caption2)).opacity(0.72)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 62)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isActive ? triggerCount : -1) {
            guard isActive, scenePhase == .active else { return }
            epoch = haptics.play(reduceMotion: reduceMotion)
            do {
                try await Task.sleep(for: .seconds(reduceMotion ? 0.7 : ShaderImpulseTimeline.duration + 0.035))
            } catch {
                haptics.stop()
                return
            }
            haptics.stop()
            onDismiss()
        }
        .onChange(of: isActive) { _, active in if !active { haptics.stop() } }
        .onChange(of: reduceMotion) { _, _ in haptics.stop(); onDismiss() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { haptics.stop(); onDismiss() }
        }
        .onDisappear { haptics.stop() }
    }
}
