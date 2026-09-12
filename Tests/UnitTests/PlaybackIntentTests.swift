// Path: Tests/UnitTests/PlaybackIntentTests.swift

import AudioEngineCore
import Foundation
import MixModels
import PlaybackCoordinator
import Testing
import TrackSource

@Suite("Playback intent", .serialized)
@MainActor
struct PlaybackIntentTests {
    @Test("Pause wins over a suspended resume snapshot")
    func pauseWins() async throws {
        let engine = IntentTestEngine()
        let coordinator = PlaybackCoordinator(source: IntentTestSource(), engine: engine, automaticallyMonitor: false)
        try await coordinator.play(trackID: TrackID(raw: "a"))
        await coordinator.pause()
        await engine.blockNextSnapshot()
        let resume = Task { try await coordinator.resume() }
        for _ in 0..<5_000 {
            if await engine.isBlocked { break }
            try await ContinuousClock().sleep(for: .milliseconds(1))
        }
        let blocked = await engine.isBlocked
        await coordinator.pause()
        await engine.releaseSnapshot()
        try await resume.value
        #expect(blocked)
        if case .paused = coordinator.snapshot().phase {} else { Issue.record("Resume overrode newer pause") }
        #expect(!(await coordinator.engineSnapshot()).deckA.isPlaying)
        await coordinator.stop()
    }
    @Test("Recovery at EOF does not prepare an empty file range")
    func recoveryAtEOF() async throws {
        let engine = IntentTestEngine()
        let coordinator = PlaybackCoordinator(source: IntentTestSource(), engine: engine, automaticallyMonitor: false)
        try await coordinator.play(trackID: TrackID(raw: "a"))
        await engine.setPosition(100)
        await coordinator.pause()
        try await coordinator.handleEngineConfigurationChange()
        let state = await coordinator.engineSnapshot()
        #expect(state.deckA.positionSeconds < 100)
        #expect(state.deckA.positionSeconds > 99.99)
        #expect(!state.deckA.isPlaying)
        await coordinator.stop()
    }
}
private actor IntentTestSource: TrackSource {
    func localFileURL(for id: TrackID) async throws -> URL { URL(fileURLWithPath: "/tmp/\(id.raw)") }
    func metadata(for id: TrackID) async throws -> TrackMeta {
        TrackMeta(id: id, title: id.raw, artist: "Test", albumID: nil, durationSec: 100, artworkURL: nil)
    }
}
private actor IntentTestEngine: PlaybackEngine {
    private var playing = false
    private var prepared = false
    private var position: Double = 0
    private var url: URL?
    private var shouldBlock = false
    private var gate: CheckedContinuation<Void, Never>?
    var isBlocked: Bool { gate != nil }
    func blockNextSnapshot() { shouldBlock = true }
    func releaseSnapshot() { gate?.resume(); gate = nil }
    func setPosition(_ value: Double) { position = value }
    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double) async throws {
        guard startTimeSeconds < 100 else { throw AudioEngineCoreError.deckNotPrepared(deck) }
        url = fileURL
        position = startTimeSeconds
        prepared = true
        playing = false
    }
    func play(_ deck: Deck) async throws { playing = true }
    func pause(_ deck: Deck) async { playing = false }
    func resume(_ deck: Deck) async throws { playing = true }
    func stop(_ deck: Deck) async {}
    func stopEngine() async { playing = false; prepared = false; url = nil }
    func setGain(_ gain: Float, for deck: Deck) async {}
    func skip(from current: Deck, to next: Deck) async throws {}
    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {}
    func snapshot() async -> AudioEngineSnapshot {
        if shouldBlock {
            shouldBlock = false
            await withCheckedContinuation { gate = $0 }
        }
        return AudioEngineSnapshot(isRunning: playing, sampleRate: 48_000, channels: 2,
            deckA: DeckPlaybackSnapshot(deck: .a, fileURL: url, isPrepared: prepared,
                isPlaying: playing, gain: 1, queuedChunks: prepared ? 1 : 0,
                reachedEndOfFile: position >= 100, positionSeconds: position, durationSeconds: 100),
            deckB: DeckPlaybackSnapshot(deck: .b, fileURL: nil, isPrepared: false,
                isPlaying: false, gain: 0, queuedChunks: 0, reachedEndOfFile: false))
    }
}
