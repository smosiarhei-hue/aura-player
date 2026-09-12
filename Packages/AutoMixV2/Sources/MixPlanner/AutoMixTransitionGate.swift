import Foundation

public enum AutoMixTransitionGateDecision: Equatable, Sendable {
    case waitingForNext
    case waitingForPlan
    case readyForPlan
    case startPlanned
    case startFallback(durationSeconds: Double)
    case hardCutAtEnd
    case queueEnded
}

public enum AutoMixTransitionGate {
    public static func decide(
        hasNext: Bool,
        nextPrepared: Bool,
        reachedEnd: Bool,
        remainingSeconds: Double,
        hasUsablePlan: Bool,
        reachedPlannedStart: Bool,
        fallbackSeconds: Double
    ) -> AutoMixTransitionGateDecision {
        guard hasNext else { return reachedEnd ? .queueEnded : .waitingForNext }
        guard nextPrepared else { return .waitingForNext }
        if reachedEnd { return .hardCutAtEnd }
        if hasUsablePlan {
            return reachedPlannedStart ? .startPlanned : .readyForPlan
        }
        let remaining = remainingSeconds.isFinite ? max(0, remainingSeconds) : .greatestFiniteMagnitude
        let fallback = min(12, max(0.75, fallbackSeconds.isFinite ? fallbackSeconds : 6))
        if remaining <= fallback {
            return .startFallback(durationSeconds: max(0.05, min(fallback, remaining)))
        }
        return .waitingForPlan
    }
}
