// Path: Aurora/AutoMix/AutoMixTransitionEnvelopes.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func actionEnvelopes(
        strategy: TransitionStrategy,
        duration: Double
    ) -> [TransitionAction] {
        let d = max(2.5, duration)
        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ:
            return bassSwap(duration: d)
        default:
            return energyBlend(duration: d)
        }
    }

    nonisolated private static func bassSwap(duration d: Double) -> [TransitionAction] {
        [
            // Outgoing Track: smooth equal-power fade (1.0 -> 0.707 at mid -> 0.0)
            .init(time: 0, target: "source", parameter: "volume", value: 1.0, duration: 0),
            .init(time: d * 0.35, target: "source", parameter: "volume", value: 0.88, duration: d * 0.35),
            .init(time: d * 0.50, target: "source", parameter: "volume", value: 0.707, duration: d * 0.15),
            .init(time: d * 0.50, target: "source", parameter: "volume", value: 0.0, duration: d * 0.50),

            // Outgoing Bass: full until midpoint, then clean cut (-24dB) on downbeat
            .init(time: 0, target: "source", parameter: "lowEQ", value: 1.0, duration: 0),
            .init(time: d * 0.48, target: "source", parameter: "lowEQ", value: 1.0, duration: 0),
            .init(time: d * 0.50, target: "source", parameter: "lowEQ", value: 0.0, duration: d * 0.04),

            // Outgoing Reverb: subtle spatial wash during outro handoff
            .init(time: 0, target: "source", parameter: "reverb", value: 0.0, duration: 0),
            .init(time: d * 0.45, target: "source", parameter: "reverb", value: 0.0, duration: 0),
            .init(time: d * 0.50, target: "source", parameter: "reverb", value: 0.40, duration: d * 0.50),

            // Incoming Track: smooth equal-power rise (0.0 -> 0.707 at mid -> 1.0)
            .init(time: 0, target: "target", parameter: "volume", value: 0.0, duration: 0),
            .init(time: 0, target: "target", parameter: "volume", value: 0.707, duration: d * 0.50),
            .init(time: d * 0.50, target: "target", parameter: "volume", value: 1.0, duration: d * 0.50),

            // Incoming Bass: cut (-24dB) until midpoint, takes over on downbeat
            .init(time: 0, target: "target", parameter: "lowEQ", value: 0.0, duration: 0),
            .init(time: d * 0.50, target: "target", parameter: "lowEQ", value: 0.0, duration: 0),
            .init(time: d * 0.52, target: "target", parameter: "lowEQ", value: 1.0, duration: d * 0.05),

            // Incoming Mid EQ (Vocal Pocket): ducked during 1st half, opens at midpoint
            .init(time: 0, target: "target", parameter: "midEQ", value: 0.70, duration: 0),
            .init(time: d * 0.48, target: "target", parameter: "midEQ", value: 0.70, duration: 0),
            .init(time: d * 0.50, target: "target", parameter: "midEQ", value: 1.0, duration: d * 0.08)
        ]
    }

    nonisolated private static func energyBlend(duration d: Double) -> [TransitionAction] {
        bassSwap(duration: d)
    }
}
