import Foundation

/// Soft LF headroom matching `SonivoEQPreamp` in RealtimeEQ.c.
/// Mild boosts stay at unity; hot 60/120 cascades get a gentle cut so the
/// PeakLimiter / sample-peak guard does not park and muddy AirPods bass.
public enum EQHeadroom {
    public static func preamp(gains: [Float], sampleRate: Double) -> Float {
        _ = sampleRate
        guard !gains.isEmpty else { return 0 }
        let g0 = gains[0].isFinite ? gains[0] : 0
        let g1 = gains.count > 1 && gains[1].isFinite ? gains[1] : 0
        let g2 = gains.count > 2 && gains[2].isFinite ? gains[2] : 0
        let lf = max(0, g0) + 0.55 * max(0, g1) + 0.20 * max(0, g2)
        if lf <= 6.5 { return 0 }
        return -min(4.5, (lf - 6.5) * 0.60)
    }
}
