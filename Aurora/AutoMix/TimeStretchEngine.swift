import AVFoundation
import Foundation

// MARK: - Tempo sync
//
// Baseline implementation on top of AVAudioUnitTimePitch: zero dependencies,
// ships with AVFoundation, good enough for an MVP. A WSOLA implementation can
// replace the rate application later without touching the planner, because
// everything here is pure math except `applyRamp`.
//
// The rate is never applied as a jump: it eases in over N bars, the way a DJ
// nudges the tempo fader on a CDJ.

nonisolated enum TimeStretchEngine {
    /// AVAudioUnitTimePitch stays transparent within roughly +-10 %. Beyond
    /// that, percussion smears audibly, so the planner falls back to a plain
    /// crossfade instead of stretching further.
    static let minRate: Float = 0.90
    static let maxRate: Float = 1.10

    /// Rate that turns `sourceBPM` into `targetBPM`, considering double and
    /// half time. Returns nil when the required stretch is out of bounds.
    nonisolated static func rate(from sourceBPM: Double, to targetBPM: Double) -> Float? {
        guard sourceBPM > 20, targetBPM > 20 else { return nil }
        let candidates = [
            targetBPM / sourceBPM,
            targetBPM / (sourceBPM * 2),
            (targetBPM * 2) / sourceBPM
        ]
        var best = candidates[0]
        for candidate in candidates where candidate.isFinite && abs(candidate - 1) < abs(best - 1) {
            best = candidate
        }
        guard best.isFinite, best >= Double(minRate), best <= Double(maxRate) else { return nil }
        return Float(best)
    }

    nonisolated static func isWithinLimits(_ rate: Float) -> Bool {
        rate >= minRate && rate <= maxRate
    }

    /// Smoothstep ramp from 1.0 to `target` over 0...1 progress.
    nonisolated static func rampedRate(target: Float, progress: Double) -> Float {
        let clamped = Float(min(1, max(0, progress)))
        let eased = clamped * clamped * (3 - 2 * clamped)
        return 1 + (target - 1) * eased
    }

    /// Ramp length in seconds for a number of bars at a given tempo.
    nonisolated static func rampDuration(bars: Int, bpm: Double) -> TimeInterval {
        guard bpm > 20, bpm < 260 else { return 4 }
        return (60.0 / bpm) * 4.0 * Double(max(1, bars))
    }

    /// Drive one lane along the ramp. Called from the transition tick.
    nonisolated static func applyRamp(target: Float, progress: Double, to node: AVAudioUnitTimePitch) {
        let value = rampedRate(target: target, progress: progress)
        node.rate = min(maxRate, max(minRate, value))
        node.bypass = abs(node.rate - 1) < 0.0005
    }

    /// How much the wall clock drifts from audio time at a given rate, so the
    /// scrubber can be corrected while a lane is stretched.
    nonisolated static func audioTimeDrift(rate: Float, elapsed: TimeInterval) -> TimeInterval {
        elapsed * (Double(rate) - 1)
    }
}
