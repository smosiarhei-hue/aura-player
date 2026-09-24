// Path: Aurora/AutoMix/AutoMixTransitionEnvelopes.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func actionEnvelopes(
        strategy: TransitionStrategy,
        duration: Double
    ) -> [TransitionAction] {
        let d = max(4, duration)
        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ:
            return bassSwap(duration: d)
        default:
            return energyBlend(duration: d)
        }
    }

    nonisolated private static func bassSwap(duration d: Double) -> [TransitionAction] {
        [
            // Outgoing Track: volume stays near 1.0 until midpoint, then smooth fade
            .init(time: 0, target: "source", parameter: "volume", value: 1.0, duration: 0),
            .init(time: d * 0.48, target: "source", parameter: "volume", value: 0.85, duration: d * 0.10),
            .init(time: d * 0.50, target: "source", parameter: "volume", value: 0.85, duration: 0),
            .init(time: d * 0.50, target: "source", parameter: "volume", value: 0.0, duration: d * 0.50),

            // Outgoing Bass: full until midpoint, then cut (-24dB) on downbeat
            .init(time: 0, target: "source", parameter: "lowEQ", value: 1.0, duration: 0),
            .init(time: d * 0.48, target: "source", parameter: "lowEQ", value: 1.0, duration: 0),
            .init(time: d * 0.50, target: "source", parameter: "lowEQ", value: 0.0, duration: d * 0.04),

            // Outgoing Reverb/Delay tail in second half
            .init(time: 0, target: "source", parameter: "reverb", value: 0.0, duration: 0),
            .init(time: d * 0.45, target: "source", parameter: "reverb", value: 0.0, duration: 0),
            .init(time: d * 0.50, target: "source", parameter: "reverb", value: 0.55, duration: d * 0.45),

            // Incoming Track: volume builds softly to 0.70 at midpoint, then 1.0
            .init(time: 0, target: "target", parameter: "volume", value: 0.0, duration: 0),
            .init(time: 0, target: "target", parameter: "volume", value: 0.70, duration: d * 0.50),
            .init(time: d * 0.50, target: "target", parameter: "volume", value: 1.0, duration: d * 0.50),

            // Incoming Bass: cut (-24dB) until midpoint, explodes to full on downbeat
            .init(time: 0, target: "target", parameter: "lowEQ", value: 0.0, duration: 0),
            .init(time: d * 0.48, target: "target", parameter: "lowEQ", value: 0.0, duration: 0),
            .init(time: d * 0.50, target: "target", parameter: "lowEQ", value: 1.0, duration: d * 0.04),

            // Incoming Mid EQ (Vocal Pocket): ducked during 1st half, opens at midpoint
            .init(time: 0, target: "target", parameter: "midEQ", value: 0.50, duration: 0),
            .init(time: d * 0.48, target: "target", parameter: "midEQ", value: 0.50, duration: 0),
            .init(time: d * 0.50, target: "target", parameter: "midEQ", value: 1.0, duration: d * 0.08)
        ]
    }

    nonisolated private static func energyBlend(duration d: Double) -> [TransitionAction] {
        bassSwap(duration: d)
    }
}
