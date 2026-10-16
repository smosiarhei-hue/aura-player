import Foundation

/// New S + sound reveal. One finite clock for vector motion and medium tactile cues.
nonisolated enum SonivoBrandLaunchMotion {
    // Uniform speed-up keeps every visual/haptic cue phase-locked.
    static let playbackRate = 1.2
    static let duration = 3.5
    static let fadeStart = 3.78 / playbackRate
    static let exitTransitionDuration = 0.38 / playbackRate
    static let reducedPreviewTime = 2.4 / playbackRate
    static let reducedDuration = 0.35
    static let hapticOnsets: [Double] = [0.82, 1.46, 1.72].map { $0 / playbackRate }
    static let hapticStrengths: [Float] = [0.50, 0.70, 0.55]
    static let hapticSharpnesses: [Float] = [0.35, 0.45, 0.30]

    static func progress(_ time: Double, start: Double, duration: Double) -> Double {
        guard time.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, (time - start) / duration))
    }
    static func ease(_ t: Double) -> Double { 1 - pow(1 - min(1, max(0, t)), 4) }
    static func smooth(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
    static func signature(_ t: Double) -> Double { ease(progress(t * playbackRate, start: 0.12, duration: 0.7)) }
    static func contour(_ t: Double) -> Double { smooth(progress(t * playbackRate, start: 0.38, duration: 1.08)) }
    static func bar(_ t: Double, index: Int) -> Double {
        ease(progress(t * playbackRate, start: 0.91 + Double(abs(index - 2)) * 0.065, duration: 0.47))
    }
    static func pulse(_ time: Double) -> Double {
        let t = time * playbackRate
        guard t.isFinite, t > 1.52, t < 2.2 else { return 1 }
        return 1 + 0.16 * sin((t - 1.52) * .pi / 0.40) * exp(-(t - 1.52) * 4)
    }
    static func name(_ t: Double) -> Double { ease(progress(t * playbackRate, start: 1.22, duration: 0.65)) }
    static func tagline(_ t: Double) -> Double { smooth(progress(t * playbackRate, start: 1.62, duration: 0.55)) }
    static func opacity(_ t: Double) -> Double { 1 - smooth(progress(t, start: fadeStart, duration: exitTransitionDuration)) }
}
