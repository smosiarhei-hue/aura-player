// Path: Packages/AutoMixV2/Sources/PlaybackCoordinator/PlaybackCoordinator.swift

import AudioEngineCore
import Foundation
import MixModels
import TrackSource

public actor PlaybackCoordinator {
    private let source: any TrackSource
    private let engine: DualDeckAudioEngine
    private var phase: PlaybackPhase = .idle
    private var activeDeck: Deck = .a
    private var activeFileURL: URL?
    private var activeMeta: TrackMeta?
    private var shouldResumeAfterInterruption = false
    private var firstSoundLatencySeconds: Double?

    public init(source: any TrackSource, engine: DualDeckAudioEngine) {
        self.source = source
        self.engine = engine
    }

    public func play(trackID: TrackID) async throws {
        phase = .loading(trackID)
        let clock = ContinuousClock()
        let started = clock.now

        do {
            async let fileURL = source.localFileURL(for: trackID)
            async let metadata = source.metadata(for: trackID)
            let (url, meta) = try await (fileURL, metadata)

            try await engine.prepare(activeDeck, fileURL: url)
            phase = .ready(meta)
            try await engine.play(activeDeck)

            activeFileURL = url
            activeMeta = meta
            firstSoundLatencySeconds = durationSeconds(from: started, to: clock.now)
            phase = .playing(meta)
        } catch {
            phase = .failed(String(describing: error))
            throw error
        }
    }

    public func pause() async {
        guard let meta = activeMeta else { return }
        await engine.pause(activeDeck)
        phase = .paused(meta)
    }

    public func resume() async throws {
        guard let meta = activeMeta else {
            throw PlaybackCoordinatorError.noPreparedTrack
        }
        try await engine.resume(activeDeck)
        phase = .playing(meta)
    }

    public func seek(to seconds: Double) async throws {
        guard activeFileURL != nil, let meta = activeMeta else {
            throw PlaybackCoordinatorError.noPreparedTrack
        }
        try await engine.seek(activeDeck, to: max(0, seconds))
        phase = .playing(meta)
    }

    public func stop() async {
        await engine.stopEngine()
        activeFileURL = nil
        activeMeta = nil
        shouldResumeAfterInterruption = false
        phase = .idle
    }

    public func handleInterruptionBegan() async {
        shouldResumeAfterInterruption = isPlaying
        if isPlaying {
            await pause()
        }
    }

    public func handleInterruptionEnded(systemShouldResume: Bool) async throws {
        let resume = shouldResumeAfterInterruption && systemShouldResume
        shouldResumeAfterInterruption = false
        if resume {
            try await self.resume()
        }
    }

    public func handleEngineConfigurationChange() async throws {
        guard let url = activeFileURL, let meta = activeMeta else { return }
        let resume = isPlaying
        await engine.stopEngine()
        try await engine.prepare(activeDeck, fileURL: url)
        phase = .ready(meta)
        if resume {
            try await engine.play(activeDeck)
            phase = .playing(meta)
        }
    }

    public func snapshot() -> PlaybackCoordinatorSnapshot {
        PlaybackCoordinatorSnapshot(
            phase: phase,
            activeDeck: activeDeck,
            shouldResumeAfterInterruption: shouldResumeAfterInterruption,
            firstSoundLatencySeconds: firstSoundLatencySeconds
        )
    }

    public func engineSnapshot() async -> AudioEngineSnapshot {
        await engine.snapshot()
    }

    private var isPlaying: Bool {
        if case .playing = phase { return true }
        return false
    }

    private func durationSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
