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
    private let userEQ: AVAudioUnitEQ
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
            let userEQ = AVAudioUnitEQ(numberOfBands: 10)
            for slot in [a, b] {
                engine.attach(slot.player)
                engine.attach(slot.timePitch)
                engine.attach(slot.fxEQ)
                engine.attach(slot.fxDelay)
                engine.attach(slot.dryMixer)
                engine.attach(slot.fxMixer)
                engine.attach(slot.gainMixer)
                engine.connect(slot.player, to: slot.timePitch, format: format)
                engine.connect(slot.timePitch, to: slot.fxEQ, format: format)
                engine.connect(slot.fxEQ, to: slot.fxDelay, format: format)
                engine.connect(slot.fxDelay, to: slot.dryMixer, format: format)
                engine.connect(slot.dryMixer, to: slot.fxMixer, format: format)
                engine.connect(slot.fxMixer, to: slot.gainMixer, format: format)
                engine.connect(slot.gainMixer, to: engine.mainMixerNode, format: format)
                slot.resetFX()
            }
            engine.attach(userEQ)
            let frequencies: [Float] = [20, 40, 60, 90, 160, 400, 1_000, 2_500, 6_000, 16_000]
            for (index, band) in userEQ.bands.enumerated() {
                band.frequency = frequencies[index]
                band.bandwidth = 1.0
                band.filterType = index == 0 ? .lowShelf : (index == frequencies.count - 1 ? .highShelf : .parametric)
                band.gain = 0
                band.bypass = false
            }
            userEQ.bypass = true
            engine.connect(engine.mainMixerNode, to: userEQ, format: format)
            engine.connect(userEQ, to: engine.outputNode, format: format)
            a.gainMixer.outputVolume = 1
            b.gainMixer.outputVolume = 0
            return (engine, format, a, b, userEQ)
        }
        controlQueue = queue
        engine = graph.0
        outputFormat = graph.1
        deckA = graph.2
        deckB = graph.3
        userEQ = graph.4
        self.preloadPolicy = preloadPolicy
    }
    public func startEngine() async throws { try await command { try $0.startLocked() } }
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
    public func play(_ deck: Deck) async throws { try await command { try $0.playLocked($0.slot(for: deck)) } }
    public func pause(_ deck: Deck) async {
        await inspect { owner in
            if let fade = owner.fade, fade.outgoing == deck || fade.incoming == deck {
                owner.pauseLocked(owner.slot(for: fade.outgoing))
                owner.pauseLocked(owner.slot(for: fade.incoming))
            } else { owner.pauseLocked(owner.slot(for: deck)) }
        }
    }
    public func resume(_ deck: Deck) async throws {
        try await command { owner in
            if let fade = owner.fade, fade.outgoing == deck || fade.incoming == deck {
                try owner.playLocked(owner.slot(for: fade.outgoing))
                try owner.playLocked(owner.slot(for: fade.incoming))
            } else { try owner.playLocked(owner.slot(for: deck)) }
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
    public func applyUserEQ(gains: [Float], enabled: Bool) async {
        await inspect { owner in
            owner.userEQ.bypass = !enabled
            for (index, band) in owner.userEQ.bands.enumerated() {
                band.gain = enabled && index < gains.count && gains[index].isFinite ? gains[index] : 0
            }
        }
    }

    /// The user-EQ node on the master bus.
    ///
    /// `AudioEngineCore` cannot depend on the app's DSP types, so instead of the engine
    /// wiring vocal isolation itself the app attaches its own render notify here.
    public var userEQUnit: AVAudioUnitEQ { userEQ }

    /// Spectrum / DSP tap on the master mixer.
    ///
    /// The callback runs on the **audio render thread**: it must be real-time safe and must
    /// never touch audio unit parameters. `AVAudioNode` keeps one tap per bus, so a second
    /// call replaces the previous one.
    public func installMasterTap(
        bufferSize: AVAudioFrameCount = 2048,
        _ block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        controlQueue.async { [self] in
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
        }
    }

    public func removeMasterTap() {
        controlQueue.async { [self] in engine.mainMixerNode.removeTap(onBus: 0) }
    }

    /// Pitch-preserving playback rate for one deck. Range matches the legacy engine.
    public func setRate(_ rate: Float, for deck: Deck) async {
        await inspect { owner in
            let slot = owner.slot(for: deck)
            slot.rate = min(1.30, max(0.70, rate.isFinite ? rate : 1))
            slot.timePitch.rate = slot.rate
        }
    }

    /// Applies one DJ FX event to a deck.
    ///
    /// Semantics are taken verbatim from the stage-4 implementation so that moving the FX
    /// chain into the engine does not change what the transition sounds like.
    public func applyEffect(_ kind: FxKind, value: Float, param: Float?, bpm: Float, to deck: Deck) async {
        await inspect { owner in
            let slot = owner.slot(for: deck)
            guard value.isFinite else { return }
            switch kind {
            case .highPass:
                let band = slot.fxEQ.bands[1]
                band.frequency = min(18000, max(20, value))
                band.bypass = value <= 21
                // Resonance climbs as the sweep opens (bandwidth 0.8 -> 0.18).
                band.bandwidth = value > 500 ? Float(0.8 - min(1, max(0, (value - 500) / 4000)) * 0.62) : 0.8
            case .lowPass:
                let band = slot.fxEQ.bands[2]
                band.frequency = min(20000, max(100, value))
                band.bypass = value >= 19900
            case .bassKill, .bassOn:
                slot.fxEQ.bands[0].gain = min(0, max(-40, -40 * min(1, max(0, value))))
            case .echoOut:
                slot.fxDelay.wetDryMix = min(75, max(0, value))
                slot.fxDelay.feedback = min(60, max(0, param ?? 30))
                slot.fxDelay.delayTime = bpm > 0 ? min(2, max(0.05, 60 / Double(bpm) * 0.75)) : 0.375
            case .rateRamp:
                slot.rate = min(1.30, max(0.70, value))
                slot.timePitch.rate = slot.rate
            case .tapeStop:
                slot.rate = max(0.015, min(1.0, value))
                slot.timePitch.rate = slot.rate
            case .stutter:
                slot.dryMixer.outputVolume = max(0, min(1, value))
            case .reverbWash:
                slot.fxDelay.wetDryMix = min(90, max(0, value))
                slot.fxDelay.feedback = min(80, max(0, param ?? 60))
                slot.fxDelay.delayTime = bpm > 0 ? min(2, max(0.05, 60 / Double(bpm) * 0.375)) : 0.25
            case .volume:
                // value is a gain in dB, 0 dB down to -60 dB.
                let gain: Float = value <= -55 ? 0.0 : pow(10.0, value / 20.0)
                slot.dryMixer.outputVolume = min(1, max(0, gain))
            case .vocalDucking:
                let band = slot.fxEQ.bands[3]
                band.bypass = abs(value) < 0.1
                let gainDB: Float = value > 0 ? -abs(value) : value
                band.gain = max(-24, min(0, gainDB))
            }
        }
    }

    /// Returns a deck to neutral EQ, delay and rate.
    public func resetEffects(_ deck: Deck, preservingRate: Bool = false) async {
        await inspect { owner in
            owner.slot(for: deck).resetFX(preservingRate: preservingRate)
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
            if let expectedGeneration, slot.ledger.generation != expectedGeneration { throw CancellationError() }
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
                        if let chunk { owner.scheduleLocked(chunk, slot: slot); return true }
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
        guard slot.isPrepared, slot.ledger.count > 0 else { throw AudioEngineCoreError.deckNotPrepared(slot.deck) }
        try startLocked()
        slot.player.play()
        slot.isPlaying = true
        refillLocked(slot)
    }
    private func pauseLocked(_ slot: DeckSlot) { slot.player.pause(); slot.isPlaying = false }
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
        slot.durationSeconds = nil
        slot.startTimeSeconds = 0
        // A stopped deck must never keep a stuck filter, echo or pitch rate.
        slot.resetFX()
    }
    private func scheduleLocked(_ chunk: DecodedPCMChunk, slot: DeckSlot) {
        guard let ticket = slot.ledger.schedule() else { return }
        slot.durationSeconds = chunk.durationSeconds
        slot.startTimeSeconds = chunk.startTimeSeconds
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
              slot.ledger.count < preloadPolicy.initialChunksPerDeck, let worker = slot.worker else { return }
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
        if slot.reachedEndOfFile, slot.ledger.count == 0 { pauseLocked(slot) }
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
        switch deck { case .a: deckA; case .b: deckB }
    }
    private func elapsedSecondsLocked(_ slot: DeckSlot) -> Double {
        if slot.reachedEndOfFile, slot.ledger.count == 0 {
            return max(0, (slot.durationSeconds ?? slot.startTimeSeconds) - slot.startTimeSeconds)
        }
        return playerSeconds(slot) ?? 0
    }
    private func snapshotLocked(_ slot: DeckSlot) -> DeckPlaybackSnapshot {
        DeckPlaybackSnapshot(deck: slot.deck, fileURL: slot.fileURL,
                             isPrepared: slot.isPrepared, isPlaying: slot.isPlaying,
                             gain: slot.gainMixer.outputVolume, queuedChunks: slot.ledger.count,
                             reachedEndOfFile: slot.reachedEndOfFile, lastError: slot.lastError,
                             positionSeconds: slot.startTimeSeconds + max(0, elapsedSecondsLocked(slot)),
                             durationSeconds: slot.durationSeconds)
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
    // Per-deck DJ FX chain (docs/automix-stage4-acceptance.md):
    // player -> timePitch -> fxEQ -> fxDelay -> dryMixer -> fxMixer -> gainMixer -> mainMixerNode
    let timePitch = AVAudioUnitTimePitch()
    let fxEQ = AVAudioUnitEQ(numberOfBands: 4)
    let fxDelay = AVAudioUnitDelay()
    let dryMixer = AVAudioMixerNode()
    let fxMixer = AVAudioMixerNode()
    let gainMixer = AVAudioMixerNode()
    /// Last commanded playback rate, kept so `resetFX(preservingRate:)` can restore it.
    var rate: Float = 1
    var ledger: PCMBufferLedger
    var worker: PCMDecodeWorker?
    var fileURL: URL?
    var isPrepared = false
    var isPlaying = false
    var reachedEndOfFile = false
    var decodePending = false
    var lastError: String?
    var durationSeconds: Double?
    var startTimeSeconds: Double = 0
    init(deck: Deck, capacity: Int) { self.deck = deck; ledger = PCMBufferLedger(capacity: capacity) }

    /// Neutral DJ FX state. `docs/automix-stage4-acceptance.md` requires that previous,
    /// stop and interruption "возвращают нейтральные EQ, delay и rate", and that no filter
    /// or echo can stay stuck.
    func resetFX(preservingRate: Bool = false) {
        let keptRate = rate
        let keptPitch = timePitch.pitch
        dryMixer.outputVolume = 1
        let bass = fxEQ.bands[0]
        bass.filterType = .lowShelf
        bass.frequency = 180
        bass.gain = 0
        bass.bypass = false
        let hp = fxEQ.bands[1]
        hp.filterType = .highPass
        hp.frequency = 20
        hp.bandwidth = 0.8
        hp.bypass = true
        let lp = fxEQ.bands[2]
        lp.filterType = .lowPass
        lp.frequency = 20000
        lp.bandwidth = 0.8
        lp.bypass = true
        let vocal = fxEQ.bands[3]
        vocal.filterType = .parametric
        vocal.frequency = 1500
        vocal.bandwidth = 1.0
        vocal.gain = 0
        vocal.bypass = true
        fxDelay.wetDryMix = 0
        fxDelay.feedback = 0
        fxDelay.delayTime = 0.375
        rate = 1
        timePitch.rate = 1
        timePitch.pitch = 0
        timePitch.overlap = 8
        if preservingRate {
            rate = keptRate
            timePitch.rate = keptRate
            timePitch.pitch = keptPitch
        }
    }
}
private struct FadeState {
    let token = UUID()
    let outgoing: Deck
    let incoming: Deck
    let duration: Double
    let baseline: Double
}
