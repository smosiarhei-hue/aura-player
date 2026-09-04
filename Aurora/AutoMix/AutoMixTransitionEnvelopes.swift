// Path: Aurora/AutoMix/AutoMixTransitionEnvelopes.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func actionEnvelopes(
        strategy: TransitionStrategy,
        duration: Double
    ) -> [TransitionAction] {
        let d = max(2, duration)
        switch strategy {
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ:
            return bassSwap(duration: d)
        case .FILTER_TRANSITION:
            return filterTransition(duration: d)
        case .ECHO_OUT:
            return echoOut(duration: d)
        case .VOCAL_CUT:
            return vocalCut(duration: d)
        case .SILENCE_TRIM, .HARD_CUT, .DROP_SWITCH:
            return shortSwitch(duration: d)
        default:
            return energyBlend(duration: d)
        }
    }

    nonisolated private static func bassSwap(duration d: Double) -> [TransitionAction] {
        [
            .init(time: 0, target: "source", parameter: "volume", value: 1, duration: 0),
            .init(time: d * 0.35, target: "source", parameter: "volume", value: 0.78, duration: d * 0.25),
            .init(time: d * 0.70, target: "source", parameter: "volume", value: 0, duration: d * 0.30),
            .init(time: d * 0.12, target: "source", parameter: "lowEQ", value: 0.75, duration: d * 0.18),
            .init(time: d * 0.36, target: "source", parameter: "lowEQ", value: 0.04, duration: d * 0.24),
            .init(time: d * 0.42, target: "source", parameter: "reverb", value: 0.48, duration: d * 0.32),
            .init(time: 0, target: "target", parameter: "volume", value: 0, duration: 0),
            .init(time: d * 0.05, target: "target", parameter: "volume", value: 0.32, duration: d * 0.18),
            .init(time: d * 0.24, target: "target", parameter: "volume", value: 0.72, duration: d * 0.28),
            .init(time: d * 0.54, target: "target", parameter: "volume", value: 1, duration: d * 0.28),
            .init(time: 0, target: "target", parameter: "lowEQ", value: 0, duration: 0),
            .init(time: d * 0.36, target: "target", parameter: "lowEQ", value: 1, duration: d * 0.22)
        ]
    }

    nonisolated private static func energyBlend(duration d: Double) -> [TransitionAction] {
        [
            .init(time: 0, target: "source", parameter: "volume", value: 1, duration: 0),
            .init(time: d * 0.18, target: "source", parameter: "volume", value: 0.84, duration: d * 0.20),
            .init(time: d * 0.42, target: "source", parameter: "volume", value: 0.50, duration: d * 0.25),
            .init(time: d * 0.72, target: "source", parameter: "volume", value: 0, duration: d * 0.28),
            .init(time: d * 0.14, target: "source", parameter: "lowEQ", value: 0.68, duration: d * 0.18),
            .init(time: d * 0.38, target: "source", parameter: "lowEQ", value: 0.04, duration: d * 0.25),
            .init(time: d * 0.24, target: "source", parameter: "reverb", value: 0.58, duration: d * 0.42),
            .init(time: 0, target: "target", parameter: "volume", value: 0, duration: 0),
            .init(time: d * 0.04, target: "target", parameter: "volume", value: 0.28, duration: d * 0.16),
            .init(time: d * 0.22, target: "target", parameter: "volume", value: 0.66, duration: d * 0.24),
            .init(time: d * 0.48, target: "target", parameter: "volume", value: 0.92, duration: d * 0.24),
            .init(time: d * 0.72, target: "target", parameter: "volume", value: 1, duration: d * 0.20),
            .init(time: 0, target: "target", parameter: "lowEQ", value: 0, duration: 0),
            .init(time: d * 0.32, target: "target", parameter: "lowEQ", value: 1, duration: d * 0.24)
        ]
    }

    nonisolated private static func filterTransition(duration d: Double) -> [TransitionAction] {
        var actions = energyBlend(duration: d)
        actions.append(.init(time: d * 0.15, target: "source", parameter: "filter", value: 0.12, duration: d * 0.65))
        actions.append(.init(time: d * 0.20, target: "source", parameter: "highEQ", value: 0.08, duration: d * 0.58))
        return actions
    }

    nonisolated private static func echoOut(duration d: Double) -> [TransitionAction] {
        var actions = energyBlend(duration: d)
        actions.append(.init(time: d * 0.18, target: "source", parameter: "reverb", value: 0.92, duration: d * 0.55))
        return actions
    }

    nonisolated private static func vocalCut(duration d: Double) -> [TransitionAction] {
        [
            .init(time: 0, target: "source", parameter: "volume", value: 1, duration: 0),
            .init(time: d * 0.48, target: "source", parameter: "volume", value: 0, duration: d * 0.32),
            .init(time: d * 0.38, target: "source", parameter: "reverb", value: 0.72, duration: d * 0.30),
            .init(time: 0, target: "target", parameter: "volume", value: 0, duration: 0),
            .init(time: d * 0.28, target: "target", parameter: "volume", value: 0.82, duration: d * 0.30),
            .init(time: d * 0.60, target: "target", parameter: "volume", value: 1, duration: d * 0.25)
        ]
    }

    nonisolated private static func shortSwitch(duration d: Double) -> [TransitionAction] {
        [
            .init(time: 0, target: "source", parameter: "volume", value: 1, duration: 0),
            .init(time: d * 0.62, target: "source", parameter: "volume", value: 0, duration: d * 0.28),
            .init(time: 0, target: "target", parameter: "volume", value: 0, duration: 0),
            .init(time: d * 0.48, target: "target", parameter: "volume", value: 1, duration: d * 0.30)
        ]
    }
}
