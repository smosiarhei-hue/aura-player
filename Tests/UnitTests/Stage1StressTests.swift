// Path: Tests/UnitTests/Stage1StressTests.swift

import AudioEngineCore
import Foundation
import MixModels
import PlaybackCoordinator
import Testing
import TrackSource

@Suite("AutoMix V2 Stage 1 stress", .serialized)
@MainActor
struct Stage1StressTests {
    @Test("Fifty rapid next commands leave one healthy active deck")
    func fiftyRapidNextCommands() async throws {
        let engine = Stage1StressEngine()
        let coordinator = PlaybackCoordinator(
            source: Stage1StressSource(),
            engine: engine,
            automaticallyMonitor: false
        )
        let queue = (0..<8).map { TrackID(raw: "track-\($0)") }
        try await coordinator.play(queue: queue, startIndex: 0)

        for _ in 0..<50 {
            try await coordinator.next()
        }

        let playback = coordinator.snapshot()
        let audio = await coordinator.engineSnapshot()
        let active = playback.activeDeck == .a ? audio.deckA : audio.deckB
        #expect(playback.currentIndex != nil)
        #expect(active.isPrepared)
        #expect(active.isPlaying)
        #expect(active.gain == 1)
        #expect(audio.isRunning)
        await coordinator.stop()
    }

    @Test("Twenty pause resume cycles preserve playback intent")
    func repeatedPauseResume() async throws {
        let engine = Stage1StressEngine()
        let coordinator = PlaybackCoordinator(
            source: Stage1StressSource(),
            engine: engine,
            automaticallyMonitor: false
        )
        try await coordinator.play(trackID: TrackID(raw: "track"))

        for _ in 0..<20 {
            await coordinator.pause()
            try await coordinator.resume()
        }

        if case .playing = coordinator.snapshot().phase {
            #expect(true)
        } else {
            Issue.record("Playback did not recover after pause/resume stress")
        }
        #expect((await coordinator.engineSnapshot()).isRunning)
        await coordinator.stop()
    }

    @Test("Interruption resumes only when both app and system allow it")
    func interruptionIntent() async throws {
        let engine = Stage1StressEngine()
        let coordinator = PlaybackCoordinator(
            source: Stage1StressSource(),
            engine: engine,
            automaticallyMonitor: false
        )
        try await coordinator.play(trackID: TrackID(raw: "track"))
        await coordinator.handleInterruptionBegan()
        try await coordinator.handleInterruptionEnded(systemShouldResume: true)

        if case .playing = coordinator.snapshot().phase {
            #expect(true)
        } else {
            Issue.record("Playback did not resume after an allowed interruption")
        }
        await coordinator.stop()
    }
}

private actor Stage1StressSource: TrackSource {
    func localFileURL(for id: TrackID) async throws -> URL {
        URL(fileURLWithPath: "/tmp/\(id.raw).m4a")
    }

    func metadata(for id: TrackID) async throws -> TrackMeta {
        TrackMeta(
            id: id,
            title: id.raw,
            artist: "Stress Test",
            albumID: nil,
            durationSec: 180,
            artworkURL: nil
        )
    }
}

private actor Stage1StressEngine: PlaybackEngine {
    private var a = StressDeck()
    private var b = StressDeck()

    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double) async throws {
        set(deck, StressDeck(fileURL: fileURL, prepared: true, playing: false, gain: 0, position: startTimeSeconds))
    }

    func play(_ deck: Deck) async throws {
        mutate(deck) { $0.playing = true }
    }

    func pause(_ deck: Deck) async {
        mutate(deck) { $0.playing = false }
    }

    func resume(_ deck: Deck) async throws {
        mutate(deck) { $0.playing = true }
    }

    func stop(_ deck: Deck) async {
        set(deck, StressDeck())
    }

    func stopEngine() async {
        a = StressDeck()
        b = StressDeck()
    }

    func setGain(_ gain: Float, for deck: Deck) async {
        mutate(deck) { $0.gain = gain }
    }

    func skip(from current: Deck, to next: Deck) async throws {
        set(current, StressDeck())
        mutate(next) {
            $0.playing = true
            $0.gain = 1
        }
    }

    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {
        set(outgoing, StressDeck())
        mutate(incoming) {
            $0.playing = true
            $0.gain = 1
            $0.position += durationSeconds
        }
    }

    func snapshot() async -> AudioEngineSnapshot {
        AudioEngineSnapshot(
            isRunning: a.playing || b.playing,
            sampleRate: 48_000,
            channels: 2,
            deckA: a.snapshot(.a),
            deckB: b.snapshot(.b)
        )
    }

    private func set(_ deck: Deck, _ value: StressDeck) {
        if deck == .a { a = value } else { b = value }
    }

    private func mutate(_ deck: Deck, _ body: (inout StressDeck) -> Void) {
        if deck == .a { body(&a) } else { body(&b) }
    }
}

private struct StressDeck {
    var fileURL: URL?
    var prepared = false
    var playing = false
    var gain: Float = 0
    var position: Double = 0

    func snapshot(_ deck: Deck) -> DeckPlaybackSnapshot {
        DeckPlaybackSnapshot(
            deck: deck,
            fileURL: fileURL,
            isPrepared: prepared,
            isPlaying: playing,
            gain: gain,
            queuedChunks: prepared ? 3 : 0,
            reachedEndOfFile: false,
            positionSeconds: position,
            durationSeconds: prepared ? 180 : nil
        )
    }
}
