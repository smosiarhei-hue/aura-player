// Path: Sonivo/AntigravityTransitionManager.swift
// Модуль интерактивного перехода «Антигравити» для экрана «Моя волна» (iOS 26+)

import SwiftUI
import QuartzCore
import CoreMotion
import AVFoundation
import Observation
import Combine

// MARK: - 1. FSM: Состояния перехода «Антигравити»

enum AntigravityPhase: String, Sendable, Equatable {
    case idle
    case antigravity  // Queue refresh in progress; no legacy animation
}

// MARK: - Audio transition (no visual or haptic effects)

@MainActor
final class AntigravityAudioFader {
    static let shared = AntigravityAudioFader()
    private var activeRequestID: UUID?

    /// Выполняет кроссфейд звука:
    /// Спад громкости (1.0 -> 0.0 за 200 мс) -> Переключение потока -> Нарастание громкости (0.0 -> 1.0 за 300 мс)
    func performCrossfade(onSwitch: @escaping () async -> Void) async {
        let request = PlayerCore.shared.playbackRequestID
        guard PlayerCore.shared.isPlaying else { return }
        let identity = UUID()
        activeRequestID = identity
        var gainID = PlayerCore.shared.beginPlaybackFade(.wave)
        defer {
            PlayerCore.shared.endPlaybackFade(.wave, id: gainID)
            if activeRequestID == identity { activeRequestID = nil }
        }
        let fadeOutSteps = 8
        for i in 1...fadeOutSteps {
            guard !Task.isCancelled, PlayerCore.shared.isPlaying,
                  PlayerCore.shared.playbackRequestID == request else { return }
            guard PlayerCore.shared.setPlaybackFade(.wave, id: gainID, gain: 1 - Float(i) / Float(fadeOutSteps)) else { return }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
        }
        guard !Task.isCancelled, PlayerCore.shared.playbackRequestID == request,
              PlayerCore.shared.isPlaying else { return }
        await onSwitch()
        guard activeRequestID == identity, !Task.isCancelled, PlayerCore.shared.isPlaying else { return }
        // A new track invalidates the old fade. Never restore a captured, already-attenuated gain.
        PlayerCore.shared.endPlaybackFade(.wave, id: gainID)
        gainID = PlayerCore.shared.beginPlaybackFade(.wave)
        guard PlayerCore.shared.setPlaybackFade(.wave, id: gainID, gain: 0) else { return }
        let switchedRequest = PlayerCore.shared.playbackRequestID
        let fadeInSteps = 12
        for i in 1...fadeInSteps {
            guard !Task.isCancelled, PlayerCore.shared.isPlaying,
                  PlayerCore.shared.playbackRequestID == switchedRequest else { return }
            guard PlayerCore.shared.setPlaybackFade(.wave, id: gainID, gain: Float(i) / Float(fadeInSteps)) else { return }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return }
        }
    }
}

// MARK: - 4. Детекция встряхивания устройства (CoreMotion + Proximity + Fallback)

@MainActor
final class AntigravityShakeDetector {
    private let motionManager = CMMotionManager()
    private var isMonitoring = false
    private var shakeWindowStart: TimeInterval = 0
    private var reversalsCount = 0
    private var lastSign: Double = 0
    private var onShakeDetected: (() -> Void)?
    // Proximity sensor disabled per user request to prevent earpiece audio switching or blacking out screen
    private var proximityState: Bool { false }

    init(onShakeDetected: @escaping () -> Void) {
        self.onShakeDetected = onShakeDetected
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        UIDevice.current.isProximityMonitoringEnabled = false
        resetShakeState()

        if motionManager.isDeviceMotionAvailable {
            // Частота опроса: 120 Гц (ProMotion)
            motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
                guard let self, let motion else { return }
                self.processDeviceMotion(motion)
            }
        } else if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 1.0 / 120.0
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let self, let data else { return }
                self.processAccelerometer(x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z)
            }
        }
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        UIDevice.current.isProximityMonitoringEnabled = false
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        if motionManager.isAccelerometerActive {
            motionManager.stopAccelerometerUpdates()
        }
        resetShakeState()
    }

    private func resetShakeState() {
        shakeWindowStart = 0
        reversalsCount = 0
        lastSign = 0
    }

    /// Обработка CMDeviceMotion с математически вычтенной гравитацией (userAcceleration)
    private func processDeviceMotion(_ motion: CMDeviceMotion) {
        let userAcc = motion.userAcceleration
        let x = userAcc.x
        let y = userAcc.y
        let z = userAcc.z
        let totalLinear = sqrt(x * x + y * y + z * z)
        let dominant = abs(x) > abs(y) ? x : y
        processLinearShake(dominantAxis: dominant, magnitude: totalLinear)
    }

    private func processAccelerometer(x: Double, y: Double, z: Double) {
        // Вычитаем статическую 1.0g гравитацию
        let rawMag = sqrt(x * x + y * y + z * z)
        let linearMag = abs(rawMag - 1.0)
        let dominant = abs(x) > abs(y) ? x : y
        processLinearShake(dominantAxis: dominant, magnitude: linearMag)
    }

    private func processLinearShake(dominantAxis: Double, magnitude: Double) {
        let now = CACurrentMediaTime()
        let threshold = 1.40 // Порог чистого линейного ускорения без гравитации

        if magnitude >= threshold {
            let currentSign: Double = dominantAxis >= 0 ? 1.0 : -1.0

            if shakeWindowStart == 0 {
                shakeWindowStart = now
                lastSign = currentSign
                reversalsCount = 1
            } else {
                let elapsed = (now - shakeWindowStart) * 1000.0

                if elapsed > 400.0 {
                    // Окно истекло — сброс и отсчет нового окна
                    shakeWindowStart = now
                    lastSign = currentSign
                    reversalsCount = 1
                } else {
                    // Смена направления рывка (Zero-Crossing)
                    if currentSign != lastSign {
                        reversalsCount += 1
                        lastSign = currentSign

                        // Минимум 2 смены знака (туда-обратно) в окне 160 - 400 мс
                        if reversalsCount >= 2 && elapsed >= 160.0 {
                            resetShakeState()
                            onShakeDetected?()
                        }
                    }
                }
            }
        } else if shakeWindowStart > 0 && (now - shakeWindowStart) * 1000.0 > 400.0 {
            resetShakeState()
        }
    }

    /// Вызывается при системном событии UIWindow.motionEnded
    func handleSystemShakeEvent() {
        onShakeDetected?()
    }
}

// MARK: - 5. Координатор перехода «Антигравити» (FSM & UI State)

@Observable
@MainActor
final class AntigravityTransitionManager {
    static let shared = AntigravityTransitionManager()

    // FSM состояние
    private(set) var phase: AntigravityPhase = .idle

    // Антидребезг (1.2 с)
    private var lastTriggerTimestamp: TimeInterval = 0
    private var detector: AntigravityShakeDetector?
    private var isAppActive: Bool = true
    private var isModalActive: Bool = false
    private var isOnMainScreen: Bool = true

    private init() {
        self.detector = AntigravityShakeDetector { [weak self] in
            Task { @MainActor in
                guard self != nil else { return }
                NotificationCenter.default.post(name: .deviceDidShakeNotification, object: nil)
            }
        }
    }

    /// Управление жизненным циклом детектора
    func updateLifecycle(isAppActive: Bool, isModalActive: Bool, isOnMainScreen: Bool = true) {
        self.isAppActive = isAppActive
        self.isModalActive = isModalActive
        self.isOnMainScreen = isOnMainScreen

        if isAppActive && !isModalActive && isOnMainScreen {
            detector?.start()
        } else {
            detector?.stop()
        }
    }

    /// Refresh the queue only. ShaderShakeOverlayView owns all visual/haptic feedback.
    func triggerShift(forceDiscover: Bool = false) {
        guard isAppActive && !isModalActive && isOnMainScreen else { return }
        let now = CACurrentMediaTime()
        guard now - lastTriggerTimestamp > 2.6, phase == .idle else { return }
        lastTriggerTimestamp = now
        phase = .antigravity
        Task {
            await AntigravityAudioFader.shared.performCrossfade {
                let waveStore = WaveSettingsStore.shared
                if forceDiscover {
                    waveStore.diversity = .discover
                }
                let request = PlayerCore.shared.playbackRequestID
                _ = await waveStore.reseedActiveWaveQueue()
                guard PlayerCore.shared.playbackRequestID == request, PlayerCore.shared.isPlaying else { return }
                ActivePlayerPresentation.shared.next()
            }
            phase = .idle
        }
    }
}
