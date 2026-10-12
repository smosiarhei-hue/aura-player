import Foundation

/// Resonance follows the supplied 5.8 s clip; its final second is already the settled home.
/// The app removes its overlay at 4.8 s so that terminal preview hold never blocks input.
nonisolated enum SonivoLaunchMotion {
    static let duration = 4.80
    static let fadeStart = 3.75
    static let exitTransitionDuration = duration - fadeStart
    static let exitDefocusRadius = 10.0
    static let homeRevealBlurRadius = 6.0
    static let reducedPreviewTime = 3.40
    static let reducedDuration = 0.35
    static let hapticOnsets: [Double] = [0.65, 3.72]
    static let hapticStrengths: [Float] = [0.35, 0.25]

    static func surfaceTime(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(duration, max(0, time))
    }
    static func atmosphereDrift(at time: Double) -> Double {
        0.075 * sin(surfaceTime(at: time) * 0.48)
    }
    static func ringOpacity(at time: Double) -> Double {
        easeOut(progress(time, from: 0.08, duration: 1.12))
    }
    static func ringScale(at time: Double) -> Double {
        0.94 + 0.06 * easeOut(progress(time, from: 0.08, duration: 1.30))
    }
    static func ringBlur(at time: Double) -> Double {
        8 * (1 - easeOut(progress(time, from: 0.08, duration: 1.10)))
    }
    static func lightProgress(at time: Double) -> Double {
        easeInOut(progress(time, from: 0.60, duration: 1.65))
    }
    static func lightOpacity(at time: Double) -> Double {
        easeOut(progress(time, from: 0.60, duration: 0.25))
            * (1 - easeOut(progress(time, from: 1.85, duration: 0.45)))
    }
    static func wordOpacity(at time: Double) -> Double {
        easeOut(progress(time, from: 1.55, duration: 0.65))
    }
    static func taglineOpacity(at time: Double) -> Double {
        easeOut(progress(time, from: 2.35, duration: 0.60))
    }
    static func exitProgress(at time: Double) -> Double {
        easeOut(progress(time, from: fadeStart, duration: exitTransitionDuration))
    }
    static func homeRevealBlur(progress: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, progress.isFinite, progress > 0, progress < 1 else { return 0 }
        return homeRevealBlurRadius * (1 - progress)
    }
    static func opacity(at time: Double) -> Double { 1 - exitProgress(at: time) }
    static func progress(_ time: Double, from start: Double, duration: Double) -> Double {
        guard time.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, (time - start) / duration))
    }
    static func easeOut(_ fraction: Double) -> Double {
        bezier(fraction, x1: 0.23, y1: 1, x2: 0.32, y2: 1)
    }
    static func easeInOut(_ fraction: Double) -> Double {
        bezier(fraction, x1: 0.77, y1: 0, x2: 0.175, y2: 1)
    }
    private static func bezier(_ fraction: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let x = min(1, max(0, fraction.isFinite ? fraction : 0))
        if x == 0 || x == 1 { return x }
        var lo = 0.0, hi = 1.0
        for _ in 0..<14 {
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
