import Foundation

public enum NeuroMixExecutionError: Error, Sendable, Equatable {
    case invalidPlan
    case unsupportedRealtimeOperation(NeuroTransitionEventKind)
}

public protocol NeuroMixRealtimeAudio: Sendable {
    func setGain(_ gain: Double, for deck: NeuroTransitionDeck) async
    func setRate(_ rate: Double, for deck: NeuroTransitionDeck) async throws
    func setFilter(kind: NeuroTransitionEventKind, value: Double, for deck: NeuroTransitionDeck) async throws
}

public struct NeuroMixTransitionExecutor: Sendable {
    private let audio: any NeuroMixRealtimeAudio
    private let clock: ContinuousClock

    public init(audio: any NeuroMixRealtimeAudio) {
        self.audio = audio
        self.clock = ContinuousClock()
    }

    public func execute(_ plan: NeuroTransitionPlan) async throws {
        guard plan.durationSeconds >= 0,
              plan.sourceTrackID != plan.targetTrackID,
              plan.sourceRate > 0,
              plan.targetRate > 0 else {
            throw NeuroMixExecutionError.invalidPlan
        }

        await audio.setGain(plan.sourceGain, for: .outgoing)
        await audio.setGain(0, for: .incoming)

        if plan.durationSeconds == 0 {
            await audio.setGain(0, for: .outgoing)
            await audio.setGain(plan.targetGain, for: .incoming)
            return
        }

        let tick = 0.02
        var elapsed = 0.0
        while elapsed < plan.durationSeconds {
            for event in plan.events {
                guard event.endSeconds > event.startSeconds,
                      elapsed >= event.startSeconds,
                      elapsed <= event.endSeconds else { continue }
                let progress = min(1, max(0, (elapsed - event.startSeconds) /
                    (event.endSeconds - event.startSeconds)))
                let value = event.fromValue + (event.toValue - event.fromValue) * progress
                try await apply(event, value: value)
            }
            let step = min(tick, plan.durationSeconds - elapsed)
            try await clock.sleep(for: .seconds(step))
            elapsed += step
        }
        await audio.setGain(0, for: .outgoing)
        await audio.setGain(plan.targetGain, for: .incoming)
    }

    private func apply(_ event: NeuroTransitionEvent, value: Double) async throws {
        switch event.kind {
        case .volume:
            await audio.setGain(value, for: event.deck)
        case .rateRamp:
            try await audio.setRate(value, for: event.deck)
        case .bassCut, .bassRestore, .highPassSweep, .lowPassSweep, .echoOut:
            try await audio.setFilter(kind: event.kind, value: value, for: event.deck)
        }
    }
}
