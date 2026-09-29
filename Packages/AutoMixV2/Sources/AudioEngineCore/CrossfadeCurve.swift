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
