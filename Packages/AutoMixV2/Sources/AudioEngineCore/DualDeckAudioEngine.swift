// Path: Packages/AutoMixV2/Sources/AudioEngineCore/DualDeckAudioEngine.swift

@preconcurrency import AVFAudio
import Foundation
import MixModels

public actor DualDeckAudioEngine {
    public static let preferredSampleRate = 48_000.0
    public static let preferredIOBufferDuration = 0.005

    private let engine: AVAudioEngine
    private let outputFormat: AVAudioFormat
    private let preloadPolicy: PCMPreloadPolicy
    private let deckA: DeckSlot
    private let deckB: DeckSlot
    private var crossfadeTask: Task<Void, Never>?

    public init(preloadPolicy: PCMPreloadPolicy = PCMPreloadPolicy()) throws {
        guard preloadPolicy.estimatedTotalQueuedBytes <= PCMPreloadPolicy.maximumTotalBytes,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: preloadPolicy.sampleRate,
                channels: preloadPolicy.channels,
                interleaved: false
              ) else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }

        let audioEngine = AVAudioEngine()
        let firstDeck = DeckSlot(deck: .a)
        let secondDeck = DeckSlot(deck: .b)

        audioEngine.attach(firstDeck.player)
        audioEngine.attach(firstDeck.gainMixer)
        audioEngine.attach(secondDeck.player)
        audioEngine.attach(secondDeck.gainMixer)
        audioEngine.connect(firstDeck.player, to: firstDeck.gainMixer, format: format)
        audioEngine.connect(secondDeck.player, to: secondDeck.gainMixer, format: format)
        audioEngine.connect(firstDeck.gainMixer, to: audioEngine.mainMixerNode, format: format)
        audioEngine.connect(secondDeck.gainMixer, to: audioEngine.mainMixerNode, format: format)
        firstDeck.gainMixer.outputVolume = 1
        secondDeck.gainMixer.outputVolume = 0

        engine = audioEngine
        outputFormat = format
        self.preloadPolicy = preloadPolicy
        deckA = firstDeck
        deckB = secondDeck
    }

    deinit {
        crossfadeTask?.cancel()
        deckA.feederTask?.cancel()
        deckB.feederTask?.cancel()
        engine.stop()
    }

    public func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    public func stopEngine() {
        crossfadeTask?.cancel()
        crossfadeTask = nil
        stop(.a)
        stop(.b)
        engine.stop()
    }

    public func prepare(
        _ deck: Deck,
        fileURL: URL,
        startTimeSeconds: Double = 0
    ) throws {
        let slot = slot(for: deck)
        stop(deck)
        let file = try AVAudioFile(forReading: fileURL)
        let boundedStart = max(0, startTimeSeconds)
        let sourceFrame = AVAudioFramePosition(
            (boundedStart * file.processingFormat.sampleRate).rounded(.down)
        )
        file.framePosition = min(sourceFrame, file.length)

        slot.fileURL = fileURL
        slot.file = file
        slot.converter = AVAudioConverter(from: file.processingFormat, to: outputFormat)
        guard slot.converter != nil else {
            throw AudioEngineCoreError.cannotCreateConverter
        }
        slot.reachedEndOfFile = false
        slot.queuedChunks = 0
        slot.isPrepared = true

        for _ in 0..<preloadPolicy.initialChunksPerDeck {
            guard try scheduleNextChunk(for: slot) else { break }
        }
    }

    public func play(_ deck: Deck) throws {
        let slot = slot(for: deck)
        guard slot.isPrepared else {
            throw AudioEngineCoreError.deckNotPrepared(deck)
        }
        try startEngine()
        slot.player.play()
        slot.isPlaying = true
        startFeeder(for: deck)
    }

    public func pause(_ deck: Deck) {
        let slot = slot(for: deck)
        slot.player.pause()
        slot.isPlaying = false
        slot.feederTask?.cancel()
        slot.feederTask = nil
    }

    public func resume(_ deck: Deck) throws {
        try play(deck)
    }

    public func seek(_ deck: Deck, to timeSeconds: Double) throws {
        let slot = slot(for: deck)
        guard let fileURL = slot.fileURL else {
            throw AudioEngineCoreError.deckNotPrepared(deck)
        }
        let shouldResume = slot.isPlaying
        try prepare(deck, fileURL: fileURL, startTimeSeconds: timeSeconds)
        if shouldResume {
            try play(deck)
        }
    }

    public func skip(from current: Deck, to next: Deck) throws {
        stop(current)
        setGain(1, for: next)
        try play(next)
    }

    public func stop(_ deck: Deck) {
        let slot = slot(for: deck)
        slot.feederTask?.cancel()
        slot.feederTask = nil
        slot.player.stop()
        slot.player.reset()
        slot.isPlaying = false
        slot.isPrepared = false
        slot.fileURL = nil
        slot.file = nil
        slot.converter = nil
        slot.queuedChunks = 0
        slot.reachedEndOfFile = false
    }

    public func setGain(_ gain: Float, for deck: Deck) {
        slot(for: deck).gainMixer.outputVolume = min(max(gain, 0), 1)
    }

    public func crossfade(
        from outgoing: Deck,
        to incoming: Deck,
        durationSeconds: Double
    ) async throws {
        crossfadeTask?.cancel()
        setGain(1, for: outgoing)
        setGain(0, for: incoming)
        try play(incoming)

        let duration = max(0.005, durationSeconds)
        let step = 0.005
        let steps = max(1, Int((duration / step).rounded(.up)))
        let clock = ContinuousClock()

        for index in 0...steps {
            if Task.isCancelled { return }
            let progress = Double(index) / Double(steps)
            let gains = CrossfadeCurve.gains(progress: progress)
            setGain(gains.outgoing, for: outgoing)
            setGain(gains.incoming, for: incoming)
            if index < steps {
                do {
                    try await clock.sleep(for: .milliseconds(5))
                } catch {
                    return
                }
            }
        }

        pause(outgoing)
        setGain(0, for: outgoing)
        setGain(1, for: incoming)
    }

    public func snapshot() -> AudioEngineSnapshot {
        AudioEngineSnapshot(
            isRunning: engine.isRunning,
            sampleRate: outputFormat.sampleRate,
            channels: outputFormat.channelCount,
            deckA: snapshot(for: deckA),
            deckB: snapshot(for: deckB)
        )
    }

    private func startFeeder(for deck: Deck) {
        let slot = slot(for: deck)
        slot.feederTask?.cancel()
        let interval = preloadPolicy.chunkDurationSeconds
        slot.feederTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                let shouldContinue = await self.refill(deck)
                if !shouldContinue { return }
            }
        }
    }

    private func refill(_ deck: Deck) -> Bool {
        let slot = slot(for: deck)
        guard slot.isPlaying, !slot.reachedEndOfFile else { return false }
        slot.queuedChunks = max(0, slot.queuedChunks - 1)
        do {
            return try scheduleNextChunk(for: slot)
        } catch {
            slot.reachedEndOfFile = true
            return false
        }
    }

    private func scheduleNextChunk(for slot: DeckSlot) throws -> Bool {
        guard let file = slot.file,
              let converter = slot.converter else {
            return false
        }
        guard file.framePosition < file.length else {
            slot.reachedEndOfFile = true
            return false
        }

        let outputCapacity = AVAudioFrameCount(preloadPolicy.framesPerChunk)
        let rateRatio = file.processingFormat.sampleRate / outputFormat.sampleRate
        let inputCapacity = AVAudioFrameCount(
            max(1, (Double(outputCapacity) * rateRatio).rounded(.up) + 8)
        )
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: inputCapacity
        ), let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }

        try file.read(into: inputBuffer, frameCount: inputCapacity)
        guard inputBuffer.frameLength > 0 else {
            slot.reachedEndOfFile = true
            return false
        }

        let inputBox = ConverterInputBox(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            inputBox.nextBuffer(status: outputStatus)
        }
        if status == .error {
            throw AudioEngineCoreError.conversionFailed(
                conversionError?.localizedDescription ?? "Unknown AVAudioConverter error"
            )
        }
        guard outputBuffer.frameLength > 0 else {
            slot.reachedEndOfFile = true
            return false
        }

        slot.player.scheduleBuffer(outputBuffer)
        slot.queuedChunks += 1
        if file.framePosition >= file.length {
            slot.reachedEndOfFile = true
        }
        return true
    }

    private func slot(for deck: Deck) -> DeckSlot {
        switch deck {
        case .a: deckA
        case .b: deckB
        }
    }

    private func snapshot(for slot: DeckSlot) -> DeckPlaybackSnapshot {
        DeckPlaybackSnapshot(
            deck: slot.deck,
            fileURL: slot.fileURL,
            isPrepared: slot.isPrepared,
            isPlaying: slot.isPlaying,
            gain: slot.gainMixer.outputVolume,
            queuedChunks: slot.queuedChunks,
            reachedEndOfFile: slot.reachedEndOfFile
        )
    }
}

private final class DeckSlot {
    let deck: Deck
    let player = AVAudioPlayerNode()
    let gainMixer = AVAudioMixerNode()
    var fileURL: URL?
    var file: AVAudioFile?
    var converter: AVAudioConverter?
    var isPrepared = false
    var isPlaying = false
    var queuedChunks = 0
    var reachedEndOfFile = false
    var feederTask: Task<Void, Never>?

    init(deck: Deck) {
        self.deck = deck
    }
}

private final class ConverterInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else {
            status.pointee = .endOfStream
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
}
