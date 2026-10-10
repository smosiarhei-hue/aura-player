import Foundation

nonisolated struct SonivoLaunchFocusWeights: Sendable {
    let brand: Double
    let first: Double
    let second: Double
    func value(for index: Int) -> Double {
        switch index { case 1: first; case 2: second; default: brand }
    }
}

/// True Focus choreography and tactile events share one monotonic launch clock.
nonisolated enum SonivoLaunchMotion {
    static let duration = 4.20
    static let fadeStart = 3.85
    static let reducedPreviewTime = 3.62
    static let reducedDuration = 0.35
    static let focusPadding = 10.0
    static let focusTransitionDuration = 0.50
    static let hapticOnsets: [Double] = [0.70, 1.78, 2.56, 3.36]
    static let hapticStrengths: [Float] = [1.0, 0.85, 0.90, 1.0]
    static let hapticBodyDuration = 0.24
    static let zoomTickOnsets: [Double] = [1.03, 1.52, 2.01, 2.50, 2.99, 3.40]
    static let zoomTickStrengths: [Float] = [0.24, 0.30, 0.35, 0.28, 0.21, 0.12]

    /// Material and atmosphere read the same finite launch clock; no independent loops.
    static func surfaceTime(at time: Double) -> Double {
        guard time.isFinite else { return 0 }
        return min(duration, max(0, time))
    }
    static func atmosphereDrift(at time: Double) -> Double {
        0.075 * sin(surfaceTime(at: time) * 0.48)
    }
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
    static func focusWeights(at time: Double) -> SonivoLaunchFocusWeights {
        guard time.isFinite else { return .init(brand: 1, first: 0, second: 0) }
        if time < 1.28 { return .init(brand: 1, first: 0, second: 0) }
        if time < 2.06 {
            let t = easeInOut(progress(time, from: 1.28, duration: focusTransitionDuration))
            return .init(brand: 1 - t, first: t, second: 0)
        }
        if time < 2.86 {
            let t = easeInOut(progress(time, from: 2.06, duration: focusTransitionDuration))
            return .init(brand: 0, first: 1 - t, second: t)
        }
        let t = easeInOut(progress(time, from: 2.86, duration: focusTransitionDuration))
        return .init(brand: t, first: 0, second: 1 - t)
    }
    static func blur(at time: Double, index: Int) -> Double {
        5 * (1 - focusWeights(at: time).value(for: index))
    }
    static func zoom(at time: Double, peak: Double) -> Double {
        let maximum = peak.isFinite ? min(2.2, max(1, peak)) : 1
        return maximum - (maximum - 1) * easeInOut(progress(time, from: 1.00, duration: 2.45))
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
