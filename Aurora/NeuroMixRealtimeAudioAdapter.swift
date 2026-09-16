import AudioEngineCore
import Foundation
import MixModels
import NeuroMixEngine

@MainActor
final class NeuroMixRealtimeAudioAdapter: NeuroMixRealtimeAudio {
    private let engine: DualDeckAudioEngine
    private let bpm: Float
    private let outgoingDeck: Deck
    private let incomingDeck: Deck

    init(
        engine: DualDeckAudioEngine,
        bpm: Float = 120,
        outgoingDeck: Deck = .a,
        incomingDeck: Deck = .b
    ) {
        self.engine = engine
        self.bpm = bpm > 0 ? bpm : 120
        self.outgoingDeck = outgoingDeck
        self.incomingDeck = incomingDeck
    }

    func setGain(_ gain: Double, for deck: NeuroTransitionDeck) async {
        await engine.setGain(Float(gain), for: audioDeck(deck))
    }

    func setRate(_ rate: Double, for deck: NeuroTransitionDeck) async throws {
        await engine.setRate(Float(rate), for: audioDeck(deck))
    }

    func setFilter(
        kind: NeuroTransitionEventKind,
        value: Double,
        for deck: NeuroTransitionDeck
    ) async throws {
        guard let effect = effectKind(for: kind) else {
            throw NeuroMixExecutionError.unsupportedRealtimeOperation(kind)
        }
        await engine.applyEffect(
            effect,
            value: Float(value),
            param: effect == .echoOut ? 28 : nil,
            bpm: bpm,
            to: audioDeck(deck)
        )
    }

    private func audioDeck(_ deck: NeuroTransitionDeck) -> Deck {
        deck == .outgoing ? outgoingDeck : incomingDeck
    }

    private func effectKind(for kind: NeuroTransitionEventKind) -> FxKind? {
        switch kind {
        case .bassCut: return .bassKill
        case .bassRestore: return .bassOn
        case .highPassSweep: return .highPass
        case .lowPassSweep: return .lowPass
        case .echoOut: return .echoOut
        case .volume, .rateRamp: return nil
        }
    }
}

@MainActor
final class NeuroMixRealtimeTransitionRunner {
    private let engine: DualDeckAudioEngine

    init(engine: DualDeckAudioEngine) {
        self.engine = engine
    }

    func execute(
        _ plan: NeuroTransitionPlan,
        incomingURL: URL,
        targetBPM: Double = 120,
        outgoing: Deck = .a,
        incoming: Deck = .b
    ) async throws {
        try await engine.prepare(
            incoming,
            fileURL: incomingURL,
            startTimeSeconds: plan.targetStartSeconds
        )
        await engine.setRate(Float(plan.targetRate), for: incoming)
        await engine.setGain(0, for: incoming)
        try await engine.play(outgoing)
        try await engine.play(incoming)
        let adapter = NeuroMixRealtimeAudioAdapter(
            engine: engine,
            bpm: Float(targetBPM > 0 ? targetBPM : 120),
            outgoingDeck: outgoing,
            incomingDeck: incoming
        )
        try await NeuroMixTransitionExecutor(audio: adapter).execute(plan)
        // Let the outgoing delay/echo tail decay instead of cutting it at the
        // exact end of the automation timeline.
        try await ContinuousClock().sleep(for: .milliseconds(700))
        await engine.stop(outgoing)
        await engine.setRate(1, for: incoming)
        await engine.resetEffects(incoming)
    }
}
