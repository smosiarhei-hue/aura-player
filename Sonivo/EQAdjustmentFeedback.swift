import Foundation

/// Pure control-side policy; never called by the audio renderer or automatic presets.
/// Intensity is a UIKit request, not a calibrated promise of physical motor force.
nonisolated struct EQAdjustmentFeedback {
    private var lastPulse = -Double.infinity
    mutating func intensity(from old: Float, to gain: Float, at time: Double) -> Float? {
        guard old.isFinite, gain.isFinite, time.isFinite,
              abs(gain - old) >= 0.49, time - lastPulse >= 0.060 else { return nil }
        lastPulse = time
        let distance = min(1, abs(gain) / EQGainLimits.maximum)
        return 0.16 + 0.74 * distance
    }
}
