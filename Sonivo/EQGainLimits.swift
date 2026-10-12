import Foundation

/// More bass range only; no system volume change or automatic curve migration.
nonisolated enum EQGainLimits {
    static let maximum: Float = 18
    static func range(at band: Int) -> ClosedRange<Float> { -12...(band < 3 ? maximum : 12) }
    static func clean(_ gain: Float, at band: Int) -> Float {
        guard gain.isFinite else { return 0 }
        let range = range(at:band)
        return max(range.lowerBound,min(range.upperBound,gain))
    }
}
