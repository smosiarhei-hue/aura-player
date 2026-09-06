// Path: Tests/UnitTests/PCMStreamingTests.swift

@preconcurrency import AVFAudio
@testable import AudioEngineCore
import Foundation
import MixModels
import Testing

@Suite("Continuous PCM decoding and callback generations", .serialized)
struct PCMStreamingTests {
    @Test("Default preload uses three ten-second chunks per deck")
    func defaultPolicy() {
        let policy = PCMPreloadPolicy()
        #expect(policy.isValid)
        #expect(policy.chunkDurationSeconds == 10)
        #expect(policy.initialChunksPerDeck == 3)
        #expect(policy.estimatedTotalQueuedBytes == 23_040_000)
    }

    @Test("Invalid numeric policies fail without integer conversion traps")
    func invalidPolicies() {
        let policies = [PCMPreloadPolicy(sampleRate: .nan),
                        PCMPreloadPolicy(sampleRate: .infinity),
                        PCMPreloadPolicy(chunkDurationSeconds: 0),
                        PCMPreloadPolicy(chunkDurationSeconds: -.infinity),
                        PCMPreloadPolicy(chunkDurationSeconds: .nan),
                        PCMPreloadPolicy(queuedDurationPerDeckSeconds: .greatestFiniteMagnitude),
                        PCMPreloadPolicy(channels: 0)]
        for policy in policies {
            #expect(!policy.isValid)
            #expect(throws: AudioEngineCoreError.unsupportedOutputFormat) {
                _ = try DualDeckAudioEngine(preloadPolicy: policy)
            }
        }
    }

    @Test("Only real unique callbacks free preload capacity")
    func callbackLedger() throws {
        var ledger = PCMBufferLedger(capacity: 3)
        let generation = ledger.generation
        let first = try #require(ledger.schedule())
        _ = try #require(ledger.schedule())
        _ = try #require(ledger.schedule())
        #expect(ledger.count == 3)
        #expect(ledger.schedule() == nil)
        #expect(!ledger.complete(ticket: UUID(), generation: generation))
        #expect(ledger.count == 3)
        #expect(ledger.complete(ticket: first, generation: generation))
        #expect(!ledger.complete(ticket: first, generation: generation))
        #expect(ledger.count == 2)
        _ = try #require(ledger.schedule())
        #expect(ledger.count == 3)
    }

    @Test("Callbacks from before stop or seek cannot consume new buffers")
    func staleCallbacks() throws {
        var ledger = PCMBufferLedger(capacity: 3)
        let oldGeneration = ledger.generation
        let oldTicket = try #require(ledger.schedule())
        ledger.reset()
        let newTicket = try #require(ledger.schedule())
        #expect(ledger.generation != oldGeneration)
        #expect(!ledger.complete(ticket: oldTicket, generation: oldGeneration))
        #expect(!ledger.complete(ticket: newTicket, generation: oldGeneration))
        #expect(ledger.count == 1)
        #expect(ledger.complete(ticket: newTicket, generation: ledger.generation))
        #expect(ledger.count == 0)
    }

    @Test("Mono files decode across multiple chunks without early EOF or boundary gaps",
          arguments: [44_100.0, 48_000.0])
    func continuousConversion(sourceRate: Double) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let duration = 31.25
        let url = try makeTone(in: directory, rate: sourceRate, duration: duration)
        let reader = try PCMFileReader(fileURL: url, startTimeSeconds: 0, policy: PCMPreloadPolicy())
        var frames = 0
        var chunks = 0
        var previousLastSample: Float?
        while let chunk = try reader.readChunk() {
            let buffer = chunk.buffer
            #expect(buffer.format.sampleRate == 48_000)
            #expect(buffer.format.channelCount == 2)
            #expect(!buffer.format.isInterleaved)
            #expect(buffer.format.commonFormat == .pcmFormatFloat32)
            #expect(buffer.frameLength > 0 && buffer.frameLength <= 480_000)
            let channels = try #require(buffer.floatChannelData)
            if let previousLastSample {
                #expect(abs(channels[0][0] - previousLastSample) < 0.05)
            }
            previousLastSample = channels[0][Int(buffer.frameLength) - 1]
            let sampleIndex = min(100, Int(buffer.frameLength) - 1)
            #expect(abs(channels[0][sampleIndex] - channels[1][sampleIndex]) < 0.0001)
            frames += Int(buffer.frameLength)
            chunks += 1
        }
        #expect(chunks == 4)
        #expect(abs(frames - Int(duration * 48_000)) <= 64)
        #expect(try reader.readChunk()?.buffer.frameLength == nil)
    }

    @Test("Seeking the decoder clamps negative and oversized positions")
    func decoderSeekBounds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeTone(in: directory, rate: 48_000, duration: 1)
        let beforeStart = try PCMFileReader(fileURL: url, startTimeSeconds: -100, policy: PCMPreloadPolicy())
        #expect(try beforeStart.readChunk()?.buffer.frameLength == 48_000)
        let afterEnd = try PCMFileReader(fileURL: url, startTimeSeconds: .greatestFiniteMagnitude,
                                        policy: PCMPreloadPolicy())
        #expect(try afterEnd.readChunk()?.buffer.frameLength == nil)
        #expect(throws: AudioEngineCoreError.unsupportedOutputFormat) {
            _ = try PCMFileReader(fileURL: url, startTimeSeconds: .nan, policy: PCMPreloadPolicy())
        }
    }

    @Test("Both decks preload within the queue budget and stop releases their state")
    func deckPreloadAndStop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeTone(in: directory, rate: 44_100, duration: 31.25)
        let engine = try DualDeckAudioEngine()
        try await engine.prepare(.a, fileURL: url)
        try await engine.prepare(.b, fileURL: url)
        let prepared = await engine.snapshot()
        #expect(prepared.deckA.queuedChunks == 3)
        #expect(prepared.deckB.queuedChunks == 3)
        #expect(prepared.deckA.isPrepared && prepared.deckB.isPrepared)
        #expect(!prepared.deckA.isPlaying && !prepared.deckB.isPlaying)
        await engine.stopEngine()
        let stopped = await engine.snapshot()
        #expect(stopped.deckA.queuedChunks == 0 && stopped.deckB.queuedChunks == 0)
        #expect(!stopped.deckA.isPrepared && !stopped.deckB.isPrepared)
        #expect(stopped.deckA.fileURL == nil && stopped.deckB.fileURL == nil)
    }

    @Test("Seeking a paused deck does not start playback")
    func pausedSeek() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeTone(in: directory, rate: 48_000, duration: 2)
        let engine = try DualDeckAudioEngine()
        try await engine.prepare(.a, fileURL: url)
        await engine.pause(.a)
        try await engine.seek(.a, to: 1)
        let snapshot = await engine.snapshot()
        #expect(snapshot.deckA.isPrepared)
        #expect(!snapshot.deckA.isPlaying)
        #expect(snapshot.deckA.queuedChunks == 1)
        await engine.stopEngine()
    }

    @Test("A failed preparation clears buffers and exposes the failure")
    func failedPreparation() async throws {
        let engine = try DualDeckAudioEngine()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        do {
            try await engine.prepare(.a, fileURL: url)
            Issue.record("Preparation unexpectedly succeeded for a missing file")
        } catch {
            let snapshot = await engine.snapshot()
            #expect(!snapshot.deckA.isPrepared)
            #expect(snapshot.deckA.queuedChunks == 0)
            #expect(snapshot.deckA.lastError != nil)
        }
        await engine.stopEngine()
    }

    @Test("Cancelled decoding cannot return a new PCM chunk")
    func cancelledDecoder() async throws {
        let worker = PCMDecodeWorker(fileURL: URL(fileURLWithPath: "/unused.caf"),
                                     startTimeSeconds: 0, policy: PCMPreloadPolicy())
        worker.cancel()
        do {
            _ = try await worker.next()
            Issue.record("Cancelled worker unexpectedly decoded a chunk")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeTone(in directory: URL, rate: Double, duration: Double) throws -> URL {
    let url = directory.appendingPathComponent("tone.caf")
    try autoreleasepool {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                               channels: 1, interleaved: false))
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let samples = try #require(buffer.floatChannelData)[0]
        let totalFrames = Int(rate * duration)
        var offset = 0
        while offset < totalFrames {
            let count = min(4_096, totalFrames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                samples[index] = Float(0.2 * sin(2 * Double.pi * 220 * Double(offset + index) / rate))
            }
            try writer.write(from: buffer)
            offset += count
        }
    }
    return url
}
