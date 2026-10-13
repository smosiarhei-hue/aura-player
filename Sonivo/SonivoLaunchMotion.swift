import Foundation

/// Approved 3-second close-up reveal. All visual and haptic cues use this one clock.
nonisolated enum SonivoLaunchMotion {
    static let duration = 3.0
    static let fadeStart = 2.30
    static let exitTransitionDuration = 0.45
    static let exitDefocusRadius = 0.0
    static let homeRevealBlurRadius = 0.0
    static let reducedPreviewTime = 1.95
    static let reducedDuration = 0.35
    static let hapticOnsets: [Double] = [1.12, 1.53, 2.30]
    static let hapticStrengths: [Float] = [1.00, 0.95, 0.80]
    static let hapticSharpnesses: [Float] = [0.65, 0.75, 0.50]
    static let hapticTravelOnset = 0.08
    static let hapticTravelDuration = 0.98
    static let shutterDuration = 1.0 / 60.0

    static func surfaceTime(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(duration, max(0, time))
    }
    static func atmosphereDrift(at time: Double) -> Double { 0 }
    static func ringOpacity(at time: Double) -> Double {
        easeOut(progress(time, from: 0.025, duration: 0.25))
    }
    static func ringScale(at time: Double) -> Double {
        let t = surfaceTime(at: time)
        guard t < 1.95 else { return 1 }
        return (1 + 3.6 * (1 - spring(max(0, t - 0.07), frequency: 9, damping: 0.94)))
            * (1 + 0.029 * impact(at: t, start: hapticOnsets[0], decay: 11))
    }
    static func wordScale(at time: Double) -> Double {
        let t = surfaceTime(at: time)
        guard t < 1.95 else { return 1 }
        return (1 + 0.65 * (1 - spring(max(0, t - 0.82), frequency: 11, damping: 0.96)))
            * (1 + 0.012 * impact(at: t, start: hapticOnsets[1], decay: 14))
    }
    static func ringBlur(at time: Double) -> Double { 0 } // No isotropic movement defocus.
    static func lightProgress(at time: Double) -> Double { progress(time, from: 1.45, duration: 0.43) }
    static func lightOpacity(at time: Double) -> Double {
        let p = lightProgress(at: time)
        return p > 0 && p < 1 ? 0.82 : 0
    }
    static func impact(at time: Double, start: Double, decay: Double) -> Double {
        let t = surfaceTime(at: time) - start
        guard t >= 0 else { return 0 }
        return exp(-decay * t) * sin(28 * t)
    }
    static func fixationFlash(at time: Double) -> Double {
        let t = surfaceTime(at: time) - hapticOnsets[0]
        guard t >= 0 else { return 0 }
        return exp(-13 * t) * sin(min(1, t / 0.085) * .pi / 2) * 0.27
    }
    static func waveProgress(at time: Double) -> Double { progress(time, from: hapticOnsets[0], duration: 0.43) }
    static func waveOpacity(at time: Double) -> Double {
        let p = waveProgress(at: time)
        return p > 0 && p < 1 ? 0.78 * pow(1 - p, 2) : 0
    }
    static func wordOpacity(at time: Double) -> Double { easeOut(progress(time, from: 0.82, duration: 0.43)) }
    static func taglineOpacity(at time: Double) -> Double { easeOut(progress(time, from: 1.42, duration: 0.35)) }
    static func exitProgress(at time: Double) -> Double { easeInOut(progress(time, from: fadeStart, duration: exitTransitionDuration)) }
    static func homeRevealBlur(progress: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, progress.isFinite, progress > 0, progress < 1 else { return 0 }
        return homeRevealBlurRadius * (1 - progress)
    }
    static func opacity(at time: Double) -> Double { 1 - exitProgress(at: time) }
    static func progress(_ time: Double, from start: Double, duration: Double) -> Double {
        guard time.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, (time - start) / duration))
    }
    private static func spring(_ t: Double, frequency: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let d = sqrt(1 - damping * damping)
        return 1 - exp(-damping * frequency * t)
            * (cos(frequency * d * t) + damping / d * sin(frequency * d * t))
    }
    static func easeOut(_ fraction: Double) -> Double { bezier(fraction, x1: 0.23, y1: 1, x2: 0.32, y2: 1) }
    static func easeInOut(_ fraction: Double) -> Double { bezier(fraction, x1: 0.77, y1: 0, x2: 0.175, y2: 1) }
    private static func bezier(_ fraction: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let x = min(1, max(0, fraction.isFinite ? fraction : 0))
        if x == 0 || x == 1 { return x }
        var lo = 0.0, hi = 1.0
        for _ in 0..<18 {
            let t = (lo + hi) * 0.5, u = 1 - t
            let sampleX = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
            if sampleX < x { lo = t } else { hi = t }
        }
        let t = (lo + hi) * 0.5, u = 1 - t
        return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
    }
}

/// In-memory launch lifetime only. Returning from the background does not replay the intro.
nonisolated struct SonivoLaunchSession {
    private(set) var hasStarted = false
    private(set) var isFinished = false

    mutating func begin(isActive: Bool, isPlaying: Bool) -> Bool {
        guard isActive, !hasStarted, !isFinished else { return false }
        if isPlaying { isFinished = true; return false }
        hasStarted = true
        return true
    }
    mutating func finish() { isFinished = true }
}

/// One startup decision per process, including recreated SwiftUI hosts. Never persisted to disk.
nonisolated struct SonivoStartupGate {
    private(set) var hasClaimed = false
    static let debounceSeconds = 0.30
    mutating func claim() -> Bool {
        guard !hasClaimed else { return false }
        hasClaimed = true
        return true
    }
    static func needsPreparation(restoringAccount: Bool, scanningLibrary: Bool,
                                 hasCachedTracks: Bool) -> Bool {
        restoringAccount || (scanningLibrary && !hasCachedTracks)
    }
}

@MainActor
final class SonivoLaunchLifetime {
    static let shared = SonivoLaunchLifetime()
    private var gate = SonivoStartupGate()
    func claim() -> Bool { gate.claim() }
}
