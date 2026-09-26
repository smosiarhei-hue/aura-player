// Path: Aurora/AntigravityTransitionManager.swift
// Модуль интерактивного перехода «Антигравити» для экрана «Моя волна» (iOS 26+)

import SwiftUI
import CoreMotion
import CoreHaptics
import AVFoundation
import Observation
import Combine

// MARK: - 1. FSM: Состояния перехода «Антигравити»

enum AntigravityPhase: String, Sendable, Equatable {
    case idle
    case antigravity  // Фаза невесомости (0 - 450мс): вихрь, 3D-кувырок плашек, левитация, растворение текста
    case settling     // Фаза стабилизации (450 - 800мс): приземление плашек, появление нового текста, фейдин звука
}

// MARK: - 2. Тактильная отдача CoreHaptics (Нарастание + Резкий щелчок)

@MainActor
final class AntigravityHaptics {
    static let shared = AntigravityHaptics()
    private var engine: CHHapticEngine?
    private var isEngineReady = false

    private init() {
        prepareEngine()
    }

    private func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let hapticEngine = try CHHapticEngine()
            hapticEngine.isAutoShutdownEnabled = true
            hapticEngine.resetHandler = { [weak self] in
                Task { @MainActor in
                    try? self?.engine?.start()
                    self?.isEngineReady = true
                }
            }
            hapticEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.isEngineReady = false
                }
            }
            try hapticEngine.start()
            isEngineReady = true
            engine = hapticEngine
        } catch {
            isEngineReady = false
        }
    }

    /// Воспроизводит акцентированный двухфазный паттерн:
    /// Фаза 1 (t = 0 мс): Нарастающий импульс (HapticContinuous, 0.2 -> 0.8, резкость 0.5, 120 мс)
    /// Фаза 2 (t = 120 мс): Резкий щелчок фиксации (HapticTransient, 1.0, резкость 0.9)
    func playAntigravityImpulse() {
        guard SettingsStore.shared.hapticsEnabled else { return }

        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            // Аппаратный фоллбек
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }

        do {
            if !isEngineReady {
                try engine.start()
                isEngineReady = true
            }

            // Фаза 1: Непрерывный нарастающий импульс 0..120 мс
            let continuousEvent = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.2),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0.0,
                duration: 0.120
            )

            // Динамическая кривая нарастания интенсивности от 0.2 до 0.8
            let intensityCurve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    .init(relativeTime: 0.0, value: 0.2),
                    .init(relativeTime: 0.120, value: 0.8)
                ],
                relativeTime: 0.0
            )

            // Фаза 2: Резкий акцентированный щелчок на 120 мс
            let transientEvent = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
                ],
                relativeTime: 0.120
            )

            let pattern = try CHHapticPattern(
                events: [continuousEvent, transientEvent],
                parameterCurves: [intensityCurve]
            )

            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Фоллбек при временной недоступности движка
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }
}

// MARK: - 3. Бесшовный кроссфейд звука (AVFoundation / PlayerCore)

@MainActor
final class AntigravityAudioFader {
    static let shared = AntigravityAudioFader()

    /// Выполняет кроссфейд звука:
    /// Спад громкости (1.0 -> 0.0 за 200 мс) -> Переключение потока -> Нарастание громкости (0.0 -> 1.0 за 300 мс)
    func performCrossfade(onSwitch: @escaping () async -> Void) async {
        let initialVolume = PlayerCore.shared.volume
        guard initialVolume > 0.05 else {
            await onSwitch()
            return
        }

        // Фаза спада громкости: 200 мс (8 шагов по 25 мс)
        let fadeOutSteps = 8
        for i in 1...fadeOutSteps {
            let frac = 1.0 - (Float(i) / Float(fadeOutSteps))
            PlayerCore.shared.volume = initialVolume * frac
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        PlayerCore.shared.volume = 0.0

        // Переключение источника волны в момент нулевой громкости
        await onSwitch()

        // Фаза нарастания громкости: 300 мс (12 шагов по 25 мс)
        let fadeInSteps = 12
        for i in 1...fadeInSteps {
            let frac = Float(i) / Float(fadeInSteps)
            PlayerCore.shared.volume = initialVolume * frac
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        PlayerCore.shared.volume = initialVolume
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

    // Шейдерные параметры фона (Metal Shader)
    var distortionStrength: Float = 0.0
    var vortexAngle: Float = 0.0
    var colorShift: Float = 0.0

    // Типографические параметры
    var typographyExitOpacity: Double = 1.0
    var typographyExitScale: CGFloat = 1.0
    var typographyEnterOpacity: Double = 1.0
    var typographyEnterScale: CGFloat = 1.0

    // 3D-параметры плашек нижней карусели
    var isCardsFlipped: Bool = false
    var cardsYOffset: CGFloat = 0.0

    // Антидребезг (1.2 с)
    private var lastTriggerTimestamp: TimeInterval = 0
    private var detector: AntigravityShakeDetector?
    private var isAppActive: Bool = true
    private var isModalActive: Bool = false
    private var isOnMainScreen: Bool = true

    private init() {
        self.detector = AntigravityShakeDetector { [weak self] in
            Task { @MainActor in
                self?.triggerShift()
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

    /// Обработка системного события встряхивания
    func handleSystemShakeNotification() {
        guard isAppActive && !isModalActive && isOnMainScreen else { return }
        triggerShift()
    }

    /// Основной запуск кинетического перехода «Антигравити»
    func triggerShift(forceDiscover: Bool = true) {
        guard isAppActive && !isModalActive && isOnMainScreen else { return }

        let now = CACurrentMediaTime()
        // Антидребезг: блокировка повторного вызова на 1.2 с
        guard now - lastTriggerTimestamp > 1.2 else { return }
        guard phase == .idle else { return }
        lastTriggerTimestamp = now

        // 1. Мгновенная синхронизированная тактильная отдача (задержка <= 30 мс)
        AntigravityHaptics.shared.playAntigravityImpulse()

        // 2. Вход в фазу невесомости (Antigravity Phase)
        phase = .antigravity

        // 3. Анимация фона (Metal Shader вихря 800 мс)
        withAnimation(.easeInOut(duration: 0.8)) {
            distortionStrength = 0.55
            vortexAngle = 3.14159 * 2.0 // Полный вихревой оборот
            colorShift = 1.0            // Переход в угольно-черный с неоном
        }

        // 4. Типографика: уход текущего текста (scale 1.08, opacity 0 за 250 мс)
        withAnimation(.easeOut(duration: 0.25)) {
            typographyExitOpacity = 0.0
            typographyExitScale = 1.08
        }

        // 5. 3D-кувырок плашек карусели с левитацией вверх на -24 pt
        withAnimation(.easeInOut(duration: 0.40)) {
            isCardsFlipped = true
            cardsYOffset = -24.0
        }

        // 6. Аудио-кроссфейд и перегенерация волны
        Task {
            await AntigravityAudioFader.shared.performCrossfade {
                // Переключение на «Незнакомое» и обновление потока
                let waveStore = WaveSettingsStore.shared
                if forceDiscover || waveStore.diversity != .discover {
                    waveStore.diversity = .discover
                }
                _ = await waveStore.reseedActiveWaveQueue()
                ActivePlayerPresentation.shared.next()
            }
        }

        // 7. Переход к фазе стабилизации (Settling Phase) через 420 мс
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            self.phase = .settling

            // Вход нового текста: старт из 0.92 / opacity 0 -> 1.0 со spring
            self.typographyEnterScale = 0.92
            self.typographyEnterOpacity = 0.0

            withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                self.typographyEnterScale = 1.0
                self.typographyEnterOpacity = 1.0
                // Пружинное приземление плашек на место
                self.cardsYOffset = 0.0
                self.isCardsFlipped = false
            }

            // 8. Возврат в Idle через 800 мс от старта
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.distortionStrength = 0.0
                    self.vortexAngle = 0.0
                    self.colorShift = 0.0
                    self.typographyExitOpacity = 1.0
                    self.typographyExitScale = 1.0
                }
                self.phase = .idle
            }
        }
    }
}
