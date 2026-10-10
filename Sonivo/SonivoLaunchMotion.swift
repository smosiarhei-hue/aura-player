import Foundation

/// One monotonic timeline is used by the native visuals and scheduled tactile events.
nonisolated enum SonivoLaunchMotion {
    static let brandLetters = ["S", "o", "n", "i", "v", "o"]
    static let markHeights: [Double] = [28, 58, 86, 58, 28]
    static let duration = 3.25
    static let fadeStart = 2.88
    static let hapticOnsets: [Double] = [1.00, 1.84]
    static let hapticStrengths: [Float] = [1.0, 0.80]
    static let hapticBodyDuration = 0.18
    static let reducedPreviewTime = 2.62
    static let reducedDuration = 0.35

    static func progress(_ time: Double, from start: Double, duration: Double) -> Double {
        guard time.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, (time - start) / duration))
    }
    /// Motion curves from the shared design guidance; fixed work, no allocations.
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
    static func markProgress(at time: Double, index: Int) -> Double {
        easeInOut(progress(time, from: 0.12 + Double(index) * 0.055, duration: 0.82))
    }
    static func letterProgress(at time: Double, index: Int) -> Double {
        easeOut(progress(time, from: 1.12 + Double(index) * 0.06, duration: 0.66))
    }
    static func accentVisibility(at time: Double) -> Double {
        let enter = easeOut(progress(time, from: hapticOnsets[0], duration: 0.14))
        let leave = progress(time, from: 1.28, duration: 0.48)
        return enter * (1 - leave)
    }
    static func impact(at time: Double) -> Double {
        hapticOnsets.reduce(0) { result, onset in
            let age = time - onset
            guard age >= 0, age < 0.46 else { return result }
            let attack = easeOut(progress(age, from: 0, duration: 0.06))
            let release = 1 - easeOut(progress(age, from: 0.06, duration: 0.40))
            return max(result, attack * release)
        }
    }
    static func sweep(at time: Double) -> Double {
        easeInOut(progress(time, from: 1.76, duration: 0.76))
    }
    static func opacity(at time: Double) -> Double {
        1 - easeOut(progress(time, from: fadeStart, duration: duration - fadeStart))
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
