// Path: Packages/AutoMixV2/Sources/AudioEngineCore/CrossfadeCurve.swift

import Foundation

public enum CrossfadeCurve {
    public static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let t = min(max(progress, 0), 1)
        let outGain = Float(cos(t * .pi / 2.0))
        let inGain = Float(sin(t * .pi / 2.0))
        return (outGain, inGain)
    }
}

/// Conservative fallback for unaligned tracks. Complementary smoothstep gains
/// avoid boosting correlated full-scale signals before any downstream EQ.
public enum AutoMixSafeCrossfade {
    public static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = progress.isFinite ? min(max(progress, 0), 1) : 0
        let shaped = p * p * (3 - 2 * p)
        let incoming = Float(shaped)
        return (1 - incoming, incoming)
    }
}
