import Foundation
import CoreHaptics
import AVFoundation
import UIKit

/// Apple Music-grade hardware haptics engine (Taptic Engine) driven by real-time audio beats, bass, and percussion.
/// Delivers separate, discernible tactile channels for Kick, Bass/808, and Hi-Hat/Treble,
/// synchronized with acoustic output latency for deaf and hard-of-hearing music perception (iOS 18+).
final class MusicHapticsManager: @unchecked Sendable {
    static let shared = MusicHapticsManager()

    private let queue = DispatchQueue(label: "com.aura.musichaptics", qos: .userInteractive)
    private let stateLock = NSLock()
    private var engine: CHHapticEngine?
    private var isEngineRunning = false

    // Multi-band flux and onset detection state
    private var prevKick: Float = 0
    private var prevBass: Float = 0
    private var prevHiHat: Float = 0

    private var kickThreshold: Float = 0.10
    private var bassThreshold: Float = 0.09
    private var hiHatThreshold: Float = 0.035

    private var lastKickTime: TimeInterval = 0
    private var lastBassTime: TimeInterval = 0
    private var lastHiHatTime: TimeInterval = 0

    // Cached latency compensation
    private var lastLatencyCheckTime: TimeInterval = 0
    private var cachedOutputDelay: TimeInterval = 0.025

    private init() {
        queue.async { [weak self] in
            self?.prepareEngine()
        }
    }

    /// Prepares low-latency CoreHaptics engine
    private func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let hapticEngine = try CHHapticEngine()
            hapticEngine.isAutoShutdownEnabled = true
            hapticEngine.resetHandler = { [weak self] in
                self?.queue.async {
                    try? self?.engine?.start()
                    self?.isEngineRunning = true
                }
            }
            hapticEngine.stoppedHandler = { [weak self] _ in
                self?.queue.async {
                    self?.isEngineRunning = false
                }
            }
            try hapticEngine.start()
            isEngineRunning = true
            engine = hapticEngine
        } catch {
            // Simulator or hardware unsupported
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

    /// Calculates dynamic acoustic delay based on current audio route (Speakers, AirPods, Bluetooth)
    private func computeOutputDelay() -> TimeInterval {
        let now = CACurrentMediaTime()
        if (now - lastLatencyCheckTime) > 1.0 {
            lastLatencyCheckTime = now
            let session = AVAudioSession.sharedInstance()
            let latency = session.outputLatency + session.ioBufferDuration
            // Subtract ~0.005s for Taptic Engine physical actuation rise time
            cachedOutputDelay = max(0.0, latency - 0.005)
        }
        return cachedOutputDelay
    }

    /// Analyzes an un-smoothed 32-band spectrum snapshot from the audio tap on EVERY buffer.
    /// Runs synchronously on the audio thread with minimal CPU cycles (pure arithmetic),
    /// and dispatches haptic triggers to the interactive queue.
    nonisolated func processRawBands(_ values: [Float]) {
        guard values.count >= 32 else { return }
        guard UserDefaults.standard.bool(forKey: "settings.musicHaptics") else { return }

        // 1. Compute instantaneous band energies (normalized 0...1)
        // Sub/Bass: Bands 0..<4 (approx 30 Hz – 65 Hz)
        let rawBass = (values[0] + values[1] + values[2] + values[3]) * 0.25
        // Kick punch: Bands 3..<8 (approx 54 Hz – 144 Hz)
        let rawKick = (values[3] + values[4] + values[5] + values[6] + values[7]) * 0.20
        // Hi-Hat / Crisp Percussion: Bands 26..<32 (approx 6 kHz – 16 kHz)
        let rawHiHat = (values[26] + values[27] + values[28] + values[29] + values[30] + values[31]) / 6.0

        stateLock.lock()
        // 2. Compute positive Spectral Flux (Half-Wave Rectification)
        let dKick = max(0, rawKick - prevKick)
        let dBass = max(0, rawBass - prevBass)
        let dHiHat = max(0, rawHiHat - prevHiHat)

        prevKick = rawKick
        prevBass = rawBass
        prevHiHat = rawHiHat

        // 3. Update adaptive moving average thresholds
        kickThreshold = kickThreshold * 0.90 + dKick * 0.10
        bassThreshold = bassThreshold * 0.90 + dBass * 0.10
        hiHatThreshold = hiHatThreshold * 0.90 + dHiHat * 0.10

        let now = CACurrentMediaTime()

        // 4. Onset tests
        // Kick: sharp transient in 54-144 Hz with at least 105ms spacing
        let isKick = (dKick > max(0.08, kickThreshold * 1.80))
            && (rawKick > 0.15)
            && ((now - lastKickTime) > 0.105)

        // Hi-Hat: fast crisp transient in 6-16 kHz with at least 55ms spacing (allows 16th notes)
        let isHiHat = (dHiHat > max(0.028, hiHatThreshold * 1.65))
            && (rawHiHat > 0.04)
            && ((now - lastHiHatTime) > 0.055)

        // Bass: tonal attack or 808 drop in 30-65 Hz (suppressed if kick is dominant to avoid mud)
        let isBass = !isKick
            && (dBass > max(0.07, bassThreshold * 1.80))
            && (rawBass > 0.16)
            && ((now - lastBassTime) > 0.135)

        if isKick { lastKickTime = now }
        if isHiHat { lastHiHatTime = now }
        if isBass { lastBassTime = now }

        stateLock.unlock()

        guard isKick || isHiHat || isBass else { return }

        // 5. Read user intensity scale from UserDefaults
        let intensityRaw = UserDefaults.standard.string(forKey: "settings.musicHapticsIntensity") ?? "strong"
        let scaleFactor: Float
        switch intensityRaw {
        case "soft": scaleFactor = 0.45
        case "medium": scaleFactor = 0.75
        default: scaleFactor = 1.00
        }

        let kickIntensity = min(1.0, rawKick * 1.25) * scaleFactor
        let hatIntensity = min(1.0, rawHiHat * 1.60) * scaleFactor
        let bassIntensity = min(1.0, rawBass * 1.10) * scaleFactor

        // 6. Schedule haptic playback on dedicated queue with acoustic latency compensation
        queue.async { [weak self] in
            guard let self else { return }
            let delay = self.computeOutputDelay()
            if delay > 0.005 {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.fireEvents(kick: isKick ? kickIntensity : nil,
                                   hiHat: isHiHat ? hatIntensity : nil,
                                   bass: isBass ? bassIntensity : nil)
                }
            } else {
                self.fireEvents(kick: isKick ? kickIntensity : nil,
                               hiHat: isHiHat ? hatIntensity : nil,
                               bass: isBass ? bassIntensity : nil)
            }
        }
    }

    /// Triggers distinct, physically separated Taptic Engine waveforms
    private func fireEvents(kick: Float?, hiHat: Float?, bass: Float?) {
        guard ensureEngineStarted(), let engine else { return }
        var events = [CHHapticEvent]()

        // A. Kick Drum Hit (Deep, Solid Mechanical Thump in the center of the palm)
        if let kick {
            let kickEvent = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.20, kick)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
                ],
                relativeTime: 0
            )
            events.append(kickEvent)
        }

        // B. Hi-Hat / Percussion (Ultra-sharp, delicate needle-click at the top edge)
        if let hiHat {
            let hatEvent = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.15, hiHat * 0.45)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.98)
                ],
                relativeTime: 0
            )
            events.append(hatEvent)
        }

        // C. Bass / 808 Note Attack (Deep, warm, low-frequency subwoofer rumble)
        if let bass {
            let bassEvent = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0.20, bass * 0.85)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.08)
                ],
                relativeTime: 0,
                duration: 0.075
            )
            events.append(bassEvent)
        }

        guard !events.isEmpty else { return }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Silently recover if audio session interrupts
        }
    }

    /// Plays an instant, tactile sample sequence: Kick -> Hi-Hat -> Bass,
    /// giving the user tactile feedback of the chosen strength in Settings.
    func playPreview(intensity: MusicHapticsIntensity) {
        queue.async { [weak self] in
            guard let self, self.ensureEngineStarted(), let engine = self.engine else { return }
            let scale = intensity.scaleFactor
            do {
                // 1. Kick thump at t = 0
                let kick = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.85 * scale),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
                    ],
                    relativeTime: 0
                )
                // 2. Hi-hat tick at t = 0.16s
                let hat = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35 * scale),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.98)
                    ],
                    relativeTime: 0.16
                )
                // 3. Bass rumble at t = 0.32s
                let bass = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.70 * scale),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.08)
                    ],
                    relativeTime: 0.32,
                    duration: 0.08
                )
                let pattern = try CHHapticPattern(events: [kick, hat, bass], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: CHHapticTimeImmediate)
            } catch {}
        }
    }

    func reset() {
        stateLock.lock()
        prevKick = 0
        prevBass = 0
        prevHiHat = 0
        kickThreshold = 0.10
        bassThreshold = 0.09
        hiHatThreshold = 0.035
        lastKickTime = 0
        lastBassTime = 0
        lastHiHatTime = 0
        stateLock.unlock()
    }

    func stop() {
        reset()
        queue.async { [weak self] in
            self?.engine?.stop()
            self?.isEngineRunning = false
        }
    }
}
