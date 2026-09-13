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

        let events = plan.events.flatMap { event in
            [
                (time: event.startSeconds, event: event, value: event.fromValue),
                (time: event.endSeconds, event: event, value: event.toValue)
            ]
        }.sorted { $0.time < $1.time }
        var elapsed = 0.0
        for action in events {
            let delay = max(0, action.time - elapsed)
            if delay > 0 {
                try await clock.sleep(for: .seconds(delay))
            }
            try await apply(action.event, value: action.value)
            elapsed = action.time
        }
        let remaining = max(0, plan.durationSeconds - elapsed)
        if remaining > 0 {
            try await clock.sleep(for: .seconds(remaining))
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
