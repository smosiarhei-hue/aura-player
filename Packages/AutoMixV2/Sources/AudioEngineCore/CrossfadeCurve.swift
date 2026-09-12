// Path: Packages/AutoMixV2/Sources/AudioEngineCore/CrossfadeCurve.swift

import Foundation

public enum CrossfadeCurve {
    public static func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let t = min(max(progress, 0), 1)
        let smooth = t * t * (3 - (2 * t))
        return (Float(1 - smooth), Float(smooth))
    }
}
