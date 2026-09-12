// Path: Tests/UnitTests/PlaybackCoordinatorTests.swift

import AudioEngineCore
import Foundation
import MixModels
import PlaybackCoordinator
import Testing
import TrackSource

@Suite("Queue coordinator", .serialized)
@MainActor
struct PlaybackCoordinatorTests {
    private let a = TrackID(raw: "a")
    private let b = TrackID(raw: "b")
    private let c = TrackID(raw: "c")

    @Test("Prepares B, fades once, swaps active deck, then prepares A")
    func automaticTransition() async throws {
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine)
        try await coordinator.play(queue: [a, b, c], startIndex: 0)
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        await engine.position(.a, seconds: 95)
        await coordinator.updatePlayback()
        try await eventually { coordinator.snapshot().currentIndex == 1 }
        try await eventually { coordinator.snapshot().preparedIndex == 2 }
        #expect(coordinator.snapshot().activeDeck == .b)
        let fades = await engine.fadeDurations
        #expect(fades == [5])
        await coordinator.updatePlayback()
        #expect(await engine.fadeDurations.count == 1)
        await coordinator.stop()
    }
    @Test("A finite queue ends without repeating itself")
    func queueEnd() async throws {
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine)
        try await coordinator.play(queue: [a], startIndex: 0)
        await engine.end(.a)
        await coordinator.updatePlayback()
        if case .ready = coordinator.snapshot().phase {} else { Issue.record("Expected ended ready state") }
        #expect(coordinator.snapshot().currentIndex == 0)
        #expect(await engine.skipCount == 0)
        await coordinator.stop()
    }
    @Test("Missing B waits at EOF, then hard-cuts when the file arrives")
    func delayedNext() async throws {
        let source = QueueTestSource(blockedID: "b")
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine, source: source)
        try await coordinator.play(queue: [a, b], startIndex: 0)
        try await eventually { await source.isBlocked }
        await engine.end(.a)
        await coordinator.updatePlayback()
        #expect(coordinator.snapshot().waitingForNext)
        await source.release()
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        await coordinator.updatePlayback()
        try await eventually { coordinator.snapshot().currentIndex == 1 }
        #expect(await engine.skipCount == 1)
        #expect(await engine.fadeDurations.isEmpty)
        #expect(!coordinator.snapshot().waitingForNext)
        await coordinator.stop()
    }
    @Test("Unavailable candidates are skipped only once", arguments: [TrackSourceError.trackUnavailable, .noDownloadOption])
    func unavailableCandidate(error: TrackSourceError) async throws {
        let source = QueueTestSource(errors: ["b": error])
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine, source: source)
        try await coordinator.play(queue: [a, b, c], startIndex: 0)
        try await eventually { coordinator.snapshot().preparedIndex == 2 }
        try await coordinator.next()
        #expect(coordinator.snapshot().currentIndex == 2)
        #expect(await source.requests.filter { $0 == "b" }.count == 1)
        await coordinator.stop()
    }
    @Test("Authentication failure is surfaced without a retry loop")
    func authenticationFailure() async throws {
        let source = QueueTestSource(errors: ["b": .authenticationRequired])
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine, source: source)
        try await coordinator.play(queue: [a, b, c], startIndex: 0)
        try await eventually { coordinator.snapshot().lastQueueError != nil }
        await engine.end(.a)
        for _ in 0..<10 { await coordinator.updatePlayback() }
        #expect(coordinator.snapshot().preparedIndex == nil)
        #expect(await source.requests == ["a", "b"])
        await coordinator.stop()
    }
    @Test("Paused seek and manual next do not restart playback")
    func pausedCommands() async throws {
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine)
        try await coordinator.play(queue: [a, b], startIndex: 0)
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        await coordinator.pause()
        try await coordinator.seek(to: 40)
        if case .paused = coordinator.snapshot().phase {} else { Issue.record("Seek lost pause intent") }
        let seekSnapshot = await coordinator.engineSnapshot()
        #expect(seekSnapshot.deckA.positionSeconds == 40)
        #expect(!seekSnapshot.deckA.isPlaying)
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        try await coordinator.next()
        #expect(coordinator.snapshot().activeDeck == .b)
        let nextSnapshot = await coordinator.engineSnapshot()
        #expect(!nextSnapshot.deckB.isPlaying)
        await coordinator.stop()
    }
    @Test("Queue replacement discards the old prepared deck")
    func replaceQueue() async throws {
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine)
        try await coordinator.play(queue: [a, b], startIndex: 0)
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        try await coordinator.replaceQueue([a, c])
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        let state = await coordinator.engineSnapshot()
        #expect(state.deckB.fileURL?.lastPathComponent == "c")
        try await coordinator.replaceQueue([])
        #expect(coordinator.snapshot().preparedIndex == nil)
        #expect(coordinator.snapshot().queue.isEmpty)
        #expect((await coordinator.engineSnapshot()).deckA.isPlaying)
        await coordinator.stop()
    }
    @Test("Repeated IDs retain distinct queue positions")
    func repeatedTrack() async throws {
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine)
        try await coordinator.play(queue: [a, a, b], startIndex: 0)
        try await eventually { coordinator.snapshot().preparedIndex == 1 }
        try await coordinator.next()
        #expect(coordinator.snapshot().currentIndex == 1)
        try await eventually { coordinator.snapshot().preparedIndex == 2 }
        await coordinator.stop()
    }
    @Test("Stop invalidates a source completion that ignores task cancellation")
    func stopDuringLoad() async throws {
        let source = QueueTestSource(blockedID: "a")
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine, source: source)
        let play = Task { try await coordinator.play(trackID: a) }
        try await eventually { await source.isBlocked }
        let stop = Task { await coordinator.stop() }
        await Task.yield()
        await source.release()
        _ = await play.result
        await stop.value
        #expect(coordinator.snapshot().phase == .idle)
        #expect(!(await coordinator.engineSnapshot()).isRunning)
        #expect(coordinator.snapshot().preparedIndex == nil)
    }
    @Test("A new selection wins over a stale download")
    func latestSelectionWins() async throws {
        let source = QueueTestSource(blockedID: "a")
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine, source: source)
        let first = Task { try await coordinator.play(trackID: a) }
        try await eventually { await source.isBlocked }
        let second = Task { try await coordinator.play(trackID: b) }
        await Task.yield()
        await source.release()
        _ = await first.result
        try await second.value
        #expect(coordinator.snapshot().queue == [b])
        #expect((await coordinator.engineSnapshot()).deckA.fileURL?.lastPathComponent == "b")
        await coordinator.stop()
    }
    @Test("Pause while loading is observed before the player starts")
    func pauseDuringLoad() async throws {
        let source = QueueTestSource(blockedID: "a")
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine, source: source)
        let play = Task { try await coordinator.play(trackID: a) }
        try await eventually { await source.isBlocked }
        await coordinator.pause()
        await source.release()
        try await play.value
        if case .paused = coordinator.snapshot().phase {} else { Issue.record("Load ignored pause") }
        #expect(!(await coordinator.engineSnapshot()).deckA.isPlaying)
        await coordinator.stop()
    }
    @Test("Configuration recovery retains position and paused intent")
    func configurationRecovery() async throws {
        let engine = QueueTestEngine()
        let coordinator = makeCoordinator(engine)
        try await coordinator.play(trackID: a)
        await engine.position(.a, seconds: 37)
        await coordinator.pause()
        try await coordinator.handleEngineConfigurationChange()
        let state = await coordinator.engineSnapshot()
        #expect(state.deckA.positionSeconds == 37)
        #expect(!state.deckA.isPlaying)
        await coordinator.stop()
    }
    private func makeCoordinator(_ engine: QueueTestEngine, source: QueueTestSource = QueueTestSource()) -> PlaybackCoordinator {
        PlaybackCoordinator(source: source, engine: engine, automaticallyMonitor: false)
    }
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<5_000 {
            if await condition() { return }
            try await ContinuousClock().sleep(for: .milliseconds(1))
        }
        throw QueueTestFailure.timedOut
    }
}

private enum QueueTestFailure: Error { case timedOut }
private actor QueueTestSource: TrackSource {
    private let blockedID: String?
    private let errors: [String: TrackSourceError]
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var requests: [String] = []
    var isBlocked: Bool { gate != nil }
    init(blockedID: String? = nil, errors: [String: TrackSourceError] = [:]) {
        self.blockedID = blockedID
        self.errors = errors
    }
    func localFileURL(for id: TrackID) async throws -> URL {
        requests.append(id.raw)
        if id.raw == blockedID, !released { await withCheckedContinuation { gate = $0 } }
        if let error = errors[id.raw] { throw error }
        return URL(fileURLWithPath: "/tmp/\(id.raw)")
    }
    func metadata(for id: TrackID) async throws -> TrackMeta {
        TrackMeta(id: id, title: id.raw, artist: "Test", albumID: nil, durationSec: 100, artworkURL: nil)
    }
    func release() { released = true; gate?.resume(); gate = nil }
}
private actor QueueTestEngine: PlaybackEngine {
    private var a = QueueTestDeck()
    private var b = QueueTestDeck()
    private var running = false
    private(set) var fadeDurations: [Double] = []
    private(set) var skipCount = 0
    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double) async throws {
        set(deck, QueueTestDeck(url: fileURL, prepared: true, position: startTimeSeconds))
    }
    func play(_ deck: Deck) async throws { running = true; mutate(deck) { $0.playing = true } }
    func pause(_ deck: Deck) async { mutate(deck) { $0.playing = false } }
    func resume(_ deck: Deck) async throws { try await play(deck) }
    func stop(_ deck: Deck) async { set(deck, QueueTestDeck()) }
    func stopEngine() async { a = QueueTestDeck(); b = QueueTestDeck(); running = false }
    func setGain(_ gain: Float, for deck: Deck) async { mutate(deck) { $0.gain = gain } }
    func skip(from current: Deck, to next: Deck) async throws {
        skipCount += 1
        await stop(current)
        try await play(next)
        await setGain(1, for: next)
    }
    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {
        fadeDurations.append(durationSeconds)
        await stop(outgoing)
        try await play(incoming)
        await setGain(1, for: incoming)
        mutate(incoming) { $0.position = durationSeconds }
    }
    func snapshot() async -> AudioEngineSnapshot {
        AudioEngineSnapshot(isRunning: running, sampleRate: 48_000, channels: 2,
                            deckA: a.snapshot(.a), deckB: b.snapshot(.b))
    }
    func position(_ deck: Deck, seconds: Double) { mutate(deck) { $0.position = seconds } }
    func end(_ deck: Deck) { mutate(deck) { $0.ended = true; $0.playing = false; $0.position = 100 } }
    private func set(_ deck: Deck, _ value: QueueTestDeck) { if deck == .a { a = value } else { b = value } }
    private func mutate(_ deck: Deck, _ body: (inout QueueTestDeck) -> Void) {
        if deck == .a { body(&a) } else { body(&b) }
    }
}
private struct QueueTestDeck {
    var url: URL?
    var prepared = false
    var playing = false
    var gain: Float = 0
    var position: Double = 0
    var ended = false
    func snapshot(_ deck: Deck) -> DeckPlaybackSnapshot {
        DeckPlaybackSnapshot(deck: deck, fileURL: url, isPrepared: prepared,
                             isPlaying: playing, gain: gain, queuedChunks: prepared && !ended ? 3 : 0,
                             reachedEndOfFile: ended, positionSeconds: position,
                             durationSeconds: prepared ? 100 : nil)
    }
}
