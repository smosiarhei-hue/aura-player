import Foundation
import CoreHaptics
import UIKit

/// Apple Music-grade hardware haptics engine (Taptic Engine) driven by real-time audio beats and bass.
/// Enabled via Settings -> «Универсальный доступ» -> «Тактильные сигналы музыки».
@MainActor
final class MusicHapticsManager {
    static let shared = MusicHapticsManager()

    private var engine: CHHapticEngine?
    private var isEngineRunning = false
    private var lastBeatTimestamp: TimeInterval = 0
    private var lastBassTimestamp: TimeInterval = 0

    private init() {
        prepareEngine()
    }

    /// Prepares low-latency CoreHaptics engine
    func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let hapticEngine = try CHHapticEngine()
            hapticEngine.isAutoShutdownEnabled = true
            hapticEngine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    try? self?.engine?.start()
                    self?.isEngineRunning = true
                }
            }
            hapticEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isEngineRunning = false
                }
            }
            engine = hapticEngine
        } catch {
            // CoreHaptics not supported or simulator
        }
    }

    private func ensureEngineStarted() -> Bool {
        guard let engine else { return false }
        if isEngineRunning { return true }
        do {
            try engine.start()
            isEngineRunning = true
            return true
        } catch {
            return false
        }
    }

    /// Evaluates incoming audio spectrum and fires Taptic Engine impulses matching the beat and bass.
    func process(kick: Float, bass: Float) {
        guard SettingsStore.shared.musicHapticsEnabled else { return }
        guard ensureEngineStarted() else { return }

        let now = CACurrentMediaTime()

        // 1. Kick & Percussive Beat Hit (Transient, High Sharpness: 0.75 - 0.85)
        // Emulates Apple Music's crisp percussive punch
        if kick > 0.44 && (now - lastBeatTimestamp) > 0.088 {
            lastBeatTimestamp = now
            let intensity = min(1.0, Float(kick) * 1.05)
            playHapticEvent(intensity: intensity, sharpness: 0.82)
            return
        }

        // 2. Sub-bass & 808 Resonance Drop (Deep Thud, Low Sharpness: 0.15 - 0.25)
        // Transmits acoustic sub-bass rumble physically through the chassis
        if bass > 0.54 && (now - lastBassTimestamp) > 0.14 {
            lastBassTimestamp = now
            let intensity = min(1.0, Float(bass) * 0.90)
            playHapticEvent(intensity: intensity, sharpness: 0.20)
        }
    }

    private func playHapticEvent(intensity: Float, sharpness: Float) {
        guard let engine, isEngineRunning else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // Silently recover if audio session interrupts
        }
    }

    func stop() {
        engine?.stop()
        isEngineRunning = false
    }
}
