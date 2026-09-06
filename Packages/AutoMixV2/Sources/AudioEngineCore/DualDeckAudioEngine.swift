// Path: Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift

@preconcurrency import AVFAudio
import Foundation
import MixModels

/// Invariant: graph, nodes, slots and fade state are accessed only on controlQueue.
/// Public async methods enqueue commands; decoder queues never touch audio nodes.
/// Player callbacks only enqueue ticket retirement, never decode or mutate the graph.
public final class DualDeckAudioEngine: @unchecked Sendable {
    public static let preferredSampleRate = 48_000.0
    public static let preferredIOBufferDuration = 0.005

    private let controlQueue: DispatchQueue
    private let engine: AVAudioEngine
    private let outputFormat: AVAudioFormat
    private let preloadPolicy: PCMPreloadPolicy
    private let deckA: DeckSlot
    private let deckB: DeckSlot
    private var fade: FadeState?

    public init(preloadPolicy: PCMPreloadPolicy = PCMPreloadPolicy()) throws {
        guard preloadPolicy.isValid else { throw AudioEngineCoreError.unsupportedOutputFormat }
        let queue = DispatchQueue(label: "com.sonivo.automix.audio-control", qos: .userInteractive)
        let graph = try queue.sync {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: preloadPolicy.sampleRate,
                                             channels: preloadPolicy.channels, interleaved: false) else {
                throw AudioEngineCoreError.unsupportedOutputFormat
            }
            let engine = AVAudioEngine()
            let a = DeckSlot(deck: .a, capacity: preloadPolicy.initialChunksPerDeck)
            let b = DeckSlot(deck: .b, capacity: preloadPolicy.initialChunksPerDeck)
            for slot in [a, b] {
                engine.attach(slot.player)
                engine.attach(slot.gainMixer)
                engine.connect(slot.player, to: slot.gainMixer, format: format)
                engine.connect(slot.gainMixer, to: engine.mainMixerNode, format: format)
            }
            a.gainMixer.outputVolume = 1
            b.gainMixer.outputVolume = 0
            return (engine, format, a, b)
        }
        controlQueue = queue
        engine = graph.0
        outputFormat = graph.1
        deckA = graph.2
        deckB = graph.3
        self.preloadPolicy = preloadPolicy
    }

    public func startEngine() async throws {
        try await command { try $0.startLocked() }
    }

    public func stopEngine() async {
        await inspect {
            $0.cancelFadeLocked()
            $0.stopLocked($0.deckA)
            $0.stopLocked($0.deckB)
            $0.engine.stop()
        }
    }

    public func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double = 0) async throws {
        _ = try await prepareInternal(deck, fileURL: fileURL, startTimeSeconds: startTimeSeconds)
    }

    public func play(_ deck: Deck) async throws {
        try await command { try $0.playLocked($0.slot(for: deck)) }
    }

    public func pause(_ deck: Deck) async {
        await inspect { owner in
            if let fade = owner.fade, fade.outgoing == deck || fade.incoming == deck {
                owner.pauseLocked(owner.slot(for: fade.outgoing))
                owner.pauseLocked(owner.slot(for: fade.incoming))
            } else {
                owner.pauseLocked(owner.slot(for: deck))
            }
        }
    }

    public func resume(_ deck: Deck) async throws {
        try await command { owner in
            if let fade = owner.fade, fade.outgoing == deck || fade.incoming == deck {
                try owner.playLocked(owner.slot(for: fade.outgoing))
                try owner.playLocked(owner.slot(for: fade.incoming))
            } else {
                try owner.playLocked(owner.slot(for: deck))
            }
        }
    }

    public func seek(_ deck: Deck, to timeSeconds: Double) async throws {
        let request = try await command { owner in
            let slot = owner.slot(for: deck)
            guard let url = slot.fileURL else { throw AudioEngineCoreError.deckNotPrepared(deck) }
            return (url, slot.isPlaying, slot.ledger.generation)
        }
        let generation = try await prepareInternal(deck, fileURL: request.0,
                                                  startTimeSeconds: timeSeconds,
                                                  expectedGeneration: request.2)
        if request.1 {
            try await command { owner in
                let slot = owner.slot(for: deck)
                guard slot.ledger.generation == generation else { throw CancellationError() }
                try owner.playLocked(slot)
            }
        }
    }

    public func skip(from current: Deck, to next: Deck) async throws {
        try await command { owner in
            guard current != next else { return }
            owner.cancelFadeLocked()
            let incoming = owner.slot(for: next)
            try owner.playLocked(incoming)
            owner.stopLocked(owner.slot(for: current))
            incoming.gainMixer.outputVolume = 1
        }
    }

    public func stop(_ deck: Deck) async {
        await inspect { owner in
            owner.cancelFadeLocked()
            owner.stopLocked(owner.slot(for: deck))
        }
    }

    public func setGain(_ gain: Float, for deck: Deck) async {
        await inspect { owner in
            owner.slot(for: deck).gainMixer.outputVolume = gain.isFinite ? min(max(gain, 0), 1) : 0
        }
    }

    public func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {
        let token = try await command { owner in
            guard outgoing != incoming, durationSeconds.isFinite, durationSeconds > 0 else {
                throw AudioEngineCoreError.conversionFailed("Invalid crossfade request")
            }
            owner.cancelFadeLocked()
            let a = owner.slot(for: outgoing)
            let b = owner.slot(for: incoming)
            guard a.isPlaying, !b.isPlaying, b.isPrepared, b.ledger.count > 0 else {
                throw AudioEngineCoreError.deckNotPrepared(incoming)
            }
            let baseline = owner.playerSeconds(b) ?? 0
            b.gainMixer.outputVolume = 0
            try owner.playLocked(b)
            a.gainMixer.outputVolume = 1
            let state = FadeState(outgoing: outgoing, incoming: incoming,
                                  duration: durationSeconds, baseline: baseline)
            owner.fade = state
            return state.token
        }
        try await withTaskCancellationHandler {
            do {
                while true {
                    try Task.checkCancellation()
                    let completed = try await command { try $0.advanceFadeLocked(token: token) }
                    if completed { return }
                    try await ContinuousClock().sleep(for: .milliseconds(5))
                }
            } catch {
                await inspect { owner in
                    if owner.fade?.token == token { owner.cancelFadeLocked() }
                }
                throw error
            }
        } onCancel: {
            self.controlQueue.async { [self] in
                if fade?.token == token { cancelFadeLocked() }
            }
        }
    }

    public func snapshot() async -> AudioEngineSnapshot {
        await inspect { owner in
            AudioEngineSnapshot(isRunning: owner.engine.isRunning,
                                sampleRate: owner.outputFormat.sampleRate,
                                channels: owner.outputFormat.channelCount,
                                deckA: owner.snapshotLocked(owner.deckA),
                                deckB: owner.snapshotLocked(owner.deckB))
        }
    }

    private func prepareInternal(_ deck: Deck, fileURL: URL, startTimeSeconds: Double,
                                 expectedGeneration: UUID? = nil) async throws -> UUID {
        guard startTimeSeconds.isFinite else { throw AudioEngineCoreError.unsupportedOutputFormat }
        try Task.checkCancellation()
        let request = try await command { owner in
            let slot = owner.slot(for: deck)
            if let expectedGeneration, slot.ledger.generation != expectedGeneration {
                throw CancellationError()
            }
            owner.cancelFadeLocked()
            owner.stopLocked(slot)
            let worker = PCMDecodeWorker(fileURL: fileURL, startTimeSeconds: startTimeSeconds,
                                         policy: owner.preloadPolicy)
            slot.fileURL = fileURL
            slot.worker = worker
            return (slot.ledger.generation, worker)
        }
        let generation = request.0
        let worker = request.1
        return try await withTaskCancellationHandler {
            do {
                for _ in 0..<preloadPolicy.initialChunksPerDeck {
                    try Task.checkCancellation()
                    let chunk = try await worker.next()
                    try Task.checkCancellation()
                    let hasChunk = try await command { owner in
                        let slot = owner.slot(for: deck)
                        guard slot.ledger.generation == generation else { throw CancellationError() }
                        if let chunk {
                            owner.scheduleLocked(chunk, slot: slot)
                            return true
                        }
                        slot.reachedEndOfFile = true
                        return false
                    }
                    if !hasChunk { break }
                }
                try Task.checkCancellation()
                return try await command { owner in
                    let slot = owner.slot(for: deck)
                    guard slot.ledger.generation == generation else { throw CancellationError() }
                    guard slot.ledger.count > 0 else { throw AudioEngineCoreError.deckNotPrepared(deck) }
                    slot.isPrepared = true
                    return generation
                }
            } catch {
                await inspect { owner in
                    let slot = owner.slot(for: deck)
                    guard slot.ledger.generation == generation else { return }
                    owner.stopLocked(slot)
                    if !(error is CancellationError) { slot.lastError = String(describing: error) }
                }
                throw error
            }
        } onCancel: {
            worker.cancel()
            self.controlQueue.async { [self] in
                let slot = slot(for: deck)
                if slot.ledger.generation == generation { stopLocked(slot) }
            }
        }
    }

    private func startLocked() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func playLocked(_ slot: DeckSlot) throws {
        guard slot.isPrepared, slot.ledger.count > 0 else {
            throw AudioEngineCoreError.deckNotPrepared(slot.deck)
        }
        try startLocked()
        slot.player.play()
        slot.isPlaying = true
        refillLocked(slot)
    }

    private func pauseLocked(_ slot: DeckSlot) {
        slot.player.pause()
        slot.isPlaying = false
    }

    private func stopLocked(_ slot: DeckSlot) {
        // Invalidate before stop(), which may itself invoke buffer callbacks.
        slot.ledger.reset()
        slot.worker?.cancel()
        slot.worker = nil
        slot.decodePending = false
        slot.player.stop()
        slot.player.reset()
        slot.isPlaying = false
        slot.isPrepared = false
        slot.fileURL = nil
        slot.reachedEndOfFile = false
        slot.lastError = nil
    }

    private func scheduleLocked(_ chunk: DecodedPCMChunk, slot: DeckSlot) {
        guard let ticket = slot.ledger.schedule() else { return }
        let generation = slot.ledger.generation
        let deck = slot.deck
        slot.player.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.controlQueue.async { [weak self] in
                guard let self else { return }
                let slot = self.slot(for: deck)
                guard slot.ledger.complete(ticket: ticket, generation: generation) else { return }
                self.finishIfDrainedLocked(slot)
                self.refillLocked(slot)
            }
        }
    }

    private func refillLocked(_ slot: DeckSlot) {
        guard slot.isPrepared, !slot.reachedEndOfFile, !slot.decodePending,
              slot.ledger.count < preloadPolicy.initialChunksPerDeck,
              let worker = slot.worker else { return }
        slot.decodePending = true
        let generation = slot.ledger.generation
        let deck = slot.deck
        worker.next { [weak self] result in
            guard let self else { return }
            self.controlQueue.async { [weak self] in
                guard let self else { return }
                let slot = self.slot(for: deck)
                guard slot.ledger.generation == generation else { return }
                slot.decodePending = false
                switch result {
                case .success(let chunk):
                    if let chunk {
                        self.scheduleLocked(chunk, slot: slot)
                        self.refillLocked(slot)
                    } else {
                        slot.reachedEndOfFile = true
                        self.finishIfDrainedLocked(slot)
                    }
                case .failure(let error):
                    self.cancelFadeLocked()
                    self.stopLocked(slot)
                    slot.lastError = String(describing: error)
                }
            }
        }
    }

    private func finishIfDrainedLocked(_ slot: DeckSlot) {
        if slot.reachedEndOfFile, slot.ledger.count == 0 {
            pauseLocked(slot)
        }
    }

    private func playerSeconds(_ slot: DeckSlot) -> Double? {
        guard let renderTime = slot.player.lastRenderTime,
              let time = slot.player.playerTime(forNodeTime: renderTime), time.sampleRate > 0 else { return nil }
        return Double(time.sampleTime) / time.sampleRate
    }

    private func advanceFadeLocked(token: UUID) throws -> Bool {
        guard let fade, fade.token == token else { throw CancellationError() }
        let a = slot(for: fade.outgoing)
        let b = slot(for: fade.incoming)
        if b.reachedEndOfFile, b.ledger.count == 0 { throw AudioEngineCoreError.deckNotPrepared(b.deck) }
        guard b.isPlaying, let seconds = playerSeconds(b) else { return false }
        // The polling interval does not advance progress. Pausing the player freezes its timeline.
        let progress = min(max((seconds - fade.baseline) / fade.duration, 0), 1)
        let gains = CrossfadeCurve.gains(progress: progress)
        a.gainMixer.outputVolume = gains.outgoing
        b.gainMixer.outputVolume = gains.incoming
        guard progress >= 1 else { return false }
        self.fade = nil
        stopLocked(a)
        b.gainMixer.outputVolume = 1
        return true
    }

    private func cancelFadeLocked() {
        guard let fade else { return }
        self.fade = nil
        slot(for: fade.outgoing).gainMixer.outputVolume = 1
        let incoming = slot(for: fade.incoming)
        incoming.gainMixer.outputVolume = 0
        pauseLocked(incoming)
    }

    private func slot(for deck: Deck) -> DeckSlot {
        switch deck {
        case .a: deckA
        case .b: deckB
        }
    }

    private func snapshotLocked(_ slot: DeckSlot) -> DeckPlaybackSnapshot {
        DeckPlaybackSnapshot(deck: slot.deck, fileURL: slot.fileURL,
                             isPrepared: slot.isPrepared, isPlaying: slot.isPlaying,
                             gain: slot.gainMixer.outputVolume, queuedChunks: slot.ledger.count,
                             reachedEndOfFile: slot.reachedEndOfFile, lastError: slot.lastError)
    }

    private func inspect<T: Sendable>(_ body: @escaping @Sendable (DualDeckAudioEngine) -> T) async -> T {
        await withCheckedContinuation { continuation in
            controlQueue.async { [self] in continuation.resume(returning: body(self)) }
        }
    }

    private func command<T: Sendable>(_ body: @escaping @Sendable (DualDeckAudioEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async { [self] in
                do { continuation.resume(returning: try body(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class DeckSlot {
    let deck: Deck
    let player = AVAudioPlayerNode()
    let gainMixer = AVAudioMixerNode()
    var ledger: PCMBufferLedger
    var worker: PCMDecodeWorker?
    var fileURL: URL?
    var isPrepared = false
    var isPlaying = false
    var reachedEndOfFile = false
    var decodePending = false
    var lastError: String?

    init(deck: Deck, capacity: Int) {
        self.deck = deck
        ledger = PCMBufferLedger(capacity: capacity)
    }
}

private struct FadeState {
    let token = UUID()
    let outgoing: Deck
    let incoming: Deck
    let duration: Double
    let baseline: Double
}
