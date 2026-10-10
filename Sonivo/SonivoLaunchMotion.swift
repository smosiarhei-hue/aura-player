import Foundation

/// One monotonic timeline is used by the native visuals and scheduled tactile events.
nonisolated enum SonivoLaunchMotion {
    static let brandLetters = ["S", "o", "n", "i", "v", "o"]
    static let markHeights: [Double] = [28, 58, 86, 58, 28]
    static let duration = 1.85
    static let fadeStart = 1.56
    static let hapticOnsets: [Double] = [0.48, 0.82]
    static let hapticStrengths: [Float] = [0.45, 0.22]
    static let reducedDuration = 0.35

    static func progress(_ time: Double, from start: Double, duration: Double) -> Double {
        guard time.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, (time - start) / duration))
    }
    /// Strong ease-out: cubic-bezier(0.23, 1, 0.32, 1). Fixed work, no allocations.
    static func easeOut(_ fraction: Double) -> Double {
        let x = min(1, max(0, fraction.isFinite ? fraction : 0))
        if x == 0 || x == 1 { return x }
        var lo = 0.0, hi = 1.0
        for _ in 0..<14 {
            let t = (lo + hi) * 0.5, u = 1 - t
            let sampleX = 3 * u * u * t * 0.23 + 3 * u * t * t * 0.32 + t * t * t
            if sampleX < x { lo = t } else { hi = t }
        }
        let t = (lo + hi) * 0.5, u = 1 - t
        return 3 * u * u * t + 3 * u * t * t + t * t * t
    }
    static func markProgress(at time: Double, index: Int) -> Double {
        easeOut(progress(time, from: 0.08 + Double(index) * 0.045, duration: 0.42))
    }
    static func letterProgress(at time: Double, index: Int) -> Double {
        easeOut(progress(time, from: 0.54 + Double(index) * 0.04, duration: 0.34))
    }
    static func accentVisibility(at time: Double) -> Double {
        let enter = easeOut(progress(time, from: hapticOnsets[0], duration: 0.18))
        let leave = progress(time, from: 0.76, duration: 0.30)
        return enter * (1 - leave)
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
