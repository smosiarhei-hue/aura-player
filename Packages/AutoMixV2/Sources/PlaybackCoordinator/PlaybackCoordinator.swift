// Path: Packages/AutoMixV2/Sources/PlaybackCoordinator/PlaybackCoordinator.swift

import AudioEngineCore
import Foundation
import MixModels
import TrackSource

/// Owns queue and playback intent on MainActor. Audio work remains on the engine queue.
/// Destructive commands cancel and drain older work before touching either deck.
@MainActor
public final class PlaybackCoordinator {
    private let source: any TrackSource
    private let engine: any PlaybackEngine
    private let crossfadeSeconds: Double
    private let automaticallyMonitor: Bool
    public var onChange: (@MainActor @Sendable (PlaybackCoordinatorSnapshot) -> Void)?
    private var phase: PlaybackPhase = .idle
    private var activeDeck: Deck = .a
    private var activeFileURL: URL?
    private var activeMeta: TrackMeta?
    private var queue: [TrackID] = []
    private var currentIndex: Int?
    private var prepared: PreparedTrack?
    private var wantsPlayback = false
    private var shouldResumeAfterInterruption = false
    private var firstSoundLatencySeconds: Double?
    private var lastQueueError: String?
    private var waitingForNext = false
    private var generation = UUID()
    private var busy = false
    private var commandTask: Task<Void, Error>?
    private var prefetchTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    public init(source: any TrackSource, engine: any PlaybackEngine,
                crossfadeSeconds: Double = 6, automaticallyMonitor: Bool = true) {
        self.source = source
        self.engine = engine
        self.crossfadeSeconds = crossfadeSeconds.isFinite ? max(0, crossfadeSeconds) : 6
        self.automaticallyMonitor = automaticallyMonitor
    }
    deinit {
        commandTask?.cancel()
        prefetchTask?.cancel()
        transitionTask?.cancel()
        monitorTask?.cancel()
    }
    public func play(trackID: TrackID) async throws {
        try await play(queue: [trackID], startIndex: 0)
    }
    public func play(queue newQueue: [TrackID], startIndex: Int) async throws {
        guard newQueue.indices.contains(startIndex) else { throw PlaybackCoordinatorError.noPreparedTrack }
        wantsPlayback = true
        try await runCommand { owner, token in
            await owner.engine.stopEngine()
            try owner.check(token)
            owner.queue = newQueue
            owner.currentIndex = startIndex
            owner.activeDeck = .a
            owner.activeFileURL = nil
            owner.activeMeta = nil
            owner.prepared = nil
            owner.lastQueueError = nil
            try await owner.loadActive(index: startIndex, position: 0, token: token)
        }
    }
    /// An empty queue removes future tracks, without interrupting the current audio.
    public func replaceQueue(_ newQueue: [TrackID]) async throws {
        try await runCommand { owner, token in
            await owner.engine.stop(owner.otherDeck)
            try owner.check(token)
            owner.prepared = nil
            let oldIndex = owner.currentIndex
            owner.queue = newQueue
            if let id = owner.activeMeta?.id {
                if let oldIndex, newQueue.indices.contains(oldIndex), newQueue[oldIndex] == id {
                    owner.currentIndex = oldIndex
                } else { owner.currentIndex = newQueue.firstIndex(of: id) }
            } else { owner.currentIndex = nil }
            owner.lastQueueError = nil
        }
    }
    public func next() async throws {
        guard !queue.isEmpty else { return }
        try await runCommand { owner, token in
            // A prepared candidate can be later than current + 1 when unavailable entries were skipped.
            if let next = owner.prepared {
                try await owner.promote(next, fadeDuration: nil, token: token)
            } else {
                let index = ((owner.currentIndex ?? -1) + 1) % owner.queue.count
                await owner.engine.stopEngine()
                try owner.check(token)
                owner.prepared = nil
                try await owner.loadActive(index: index, position: 0, token: token)
            }
        }
    }
    public func previous() async throws {
        guard !queue.isEmpty else { return }
        try await runCommand { owner, token in
            let index = ((owner.currentIndex ?? 0) - 1 + owner.queue.count) % owner.queue.count
            await owner.engine.stopEngine()
            try owner.check(token)
            owner.prepared = nil
            try await owner.loadActive(index: index, position: 0, token: token)
        }
    }
    public func pause() async {
        wantsPlayback = false
        let token = generation
        await engine.pause(activeDeck)
        guard token == generation else { return }
        if let meta = activeMeta { phase = wantsPlayback ? .playing(meta) : .paused(meta) }
        publish()
    }
    public func resume() async throws {
        wantsPlayback = true
        if busy { return } // A pending load observes the latest intent before starting audio.
        guard let meta = activeMeta else { throw PlaybackCoordinatorError.noPreparedTrack }
        let token = generation
        let state = await engine.snapshot()
        try check(token)
        guard wantsPlayback else { return }
        let deck = deckSnapshot(state, activeDeck)
        if deck.reachedEndOfFile && deck.queuedChunks == 0 {
            if transitionTask != nil, let next = prepared {
                // A may drain just before a paused fade completes. Resume the surviving B audio.
                try await runCommand { owner, token in
                    try await owner.promote(next, fadeDuration: nil, token: token)
                }
                return
            }
            waitingForNext = true
        } else {
            try await engine.resume(activeDeck)
            try check(token)
            if !wantsPlayback { await engine.pause(activeDeck); try check(token) }
        }
        phase = wantsPlayback ? .playing(activeMeta ?? meta) : .paused(activeMeta ?? meta)
        publish()
        startMonitor()
    }
    public func seek(to seconds: Double) async throws {
        guard seconds.isFinite else { throw AudioEngineCoreError.unsupportedOutputFormat }
        guard let url = activeFileURL, let meta = activeMeta else { throw PlaybackCoordinatorError.noPreparedTrack }
        try await runCommand { owner, token in
            let state = await owner.engine.snapshot()
            try owner.check(token)
            let duration = owner.deckSnapshot(state, owner.activeDeck).durationSeconds
            // Leave one frame available instead of trying to prepare an empty EOF deck.
            let upper = duration.map { max(0, $0 - 1 / 48_000.0) } ?? Double.greatestFiniteMagnitude
            await owner.engine.stop(owner.otherDeck)
            try owner.check(token)
            owner.prepared = nil
            try await owner.engine.prepare(owner.activeDeck, fileURL: url,
                                           startTimeSeconds: min(max(0, seconds), upper))
            try owner.check(token)
            await owner.engine.setGain(1, for: owner.activeDeck)
            try owner.check(token)
            try await owner.applyPlaybackIntent(meta: meta, token: token)
        }
    }
    public func stop() async {
        wantsPlayback = false
        do {
            try await runCommand { owner, token in
                await owner.engine.stopEngine()
                try owner.check(token)
                owner.activeFileURL = nil
                owner.activeMeta = nil
                owner.prepared = nil
                owner.queue = []
                owner.currentIndex = nil
                owner.shouldResumeAfterInterruption = false
                owner.lastQueueError = nil
                owner.phase = .idle
            }
        } catch { /* A newer command owns the engine and visible state. */ }
    }
    public func handleInterruptionBegan() async {
        shouldResumeAfterInterruption = wantsPlayback
        await pause()
    }
    public func handleInterruptionEnded(systemShouldResume: Bool) async throws {
        let shouldResume = shouldResumeAfterInterruption && systemShouldResume
        shouldResumeAfterInterruption = false
        if shouldResume { try await resume() }
        publish()
    }
    public func handleEngineConfigurationChange() async throws {
        guard let url = activeFileURL, let meta = activeMeta else { return }
        try await runCommand { owner, token in
            let snapshot = await owner.engine.snapshot()
            try owner.check(token)
            let deck = owner.deckSnapshot(snapshot, owner.activeDeck)
            let upper = deck.durationSeconds.map { max(0, $0 - 1 / 48_000.0) } ?? Double.greatestFiniteMagnitude
            let position = min(deck.positionSeconds, upper)
            await owner.engine.stopEngine()
            try owner.check(token)
            owner.prepared = nil
            try await owner.engine.prepare(owner.activeDeck, fileURL: url, startTimeSeconds: position)
            try owner.check(token)
            await owner.engine.setGain(1, for: owner.activeDeck)
            try owner.check(token)
            try await owner.applyPlaybackIntent(meta: meta, token: token)
        }
    }
    public func snapshot() -> PlaybackCoordinatorSnapshot {
        PlaybackCoordinatorSnapshot(phase: phase, activeDeck: activeDeck,
            shouldResumeAfterInterruption: shouldResumeAfterInterruption,
            firstSoundLatencySeconds: firstSoundLatencySeconds,
            queue: queue, currentIndex: currentIndex, preparedIndex: prepared?.index,
            isTransitioning: transitionTask != nil, waitingForNext: waitingForNext,
            lastQueueError: lastQueueError)
    }
    public func engineSnapshot() async -> AudioEngineSnapshot { await engine.snapshot() }
    /// Also usable by hosts with their own lifecycle clock. Timing comes from PCM, not polling elapsed time.
    public func updatePlayback() async {
        guard !busy, wantsPlayback, activeMeta != nil, transitionTask == nil else { return }
        let token = generation
        let state = await engine.snapshot()
        guard token == generation, !busy, wantsPlayback, transitionTask == nil else { return }
        let active = deckSnapshot(state, activeDeck)
        if let error = active.lastError {
            wantsPlayback = false
            phase = .failed(error)
            publish()
            return
        }
        let ended = active.reachedEndOfFile && active.queuedChunks == 0
        if let next = prepared {
            let incoming = deckSnapshot(state, next.deck)
            let remaining = active.durationSeconds.map { max(0, $0 - active.positionSeconds) }
            if ended { beginTransition(next, duration: nil, token: token) }
            else if active.isPlaying, let remaining, crossfadeSeconds > 0,
                    remaining <= crossfadeSeconds, remaining > 0.05,
                    let incomingDuration = incoming.durationSeconds, incomingDuration > 0.1 {
                beginTransition(next, duration: min(crossfadeSeconds, remaining, incomingDuration / 2), token: token)
            }
        } else if ended {
            waitingForNext = prefetchTask != nil
            if !waitingForNext {
                wantsPlayback = false
                if let meta = activeMeta { phase = .ready(meta) }
                monitorTask?.cancel()
                monitorTask = nil
            }
            publish()
        }
    }
    private var otherDeck: Deck { activeDeck == .a ? .b : .a }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }
    private func runCommand(_ operation: @escaping @MainActor @Sendable (PlaybackCoordinator, UUID) async throws -> Void) async throws {
        let token = UUID()
        generation = token
        busy = true
        waitingForNext = false
        let previous = commandTask
        let prefetch = prefetchTask
        let transition = transitionTask
        previous?.cancel()
        prefetch?.cancel()
        transition?.cancel()
        monitorTask?.cancel()
        prefetchTask = nil
        transitionTask = nil
        monitorTask = nil
        // Cancelled fades may have advanced the prepared player's timeline; never reuse that position.
        if transition != nil { prepared = nil }
        let task = Task { @MainActor [self] in
            _ = await previous?.result
            await prefetch?.value
            await transition?.value
            do {
                try check(token)
                try await operation(self, token)
                try check(token)
                busy = false
                publish()
                startPrefetch()
                startMonitor()
            } catch {
                guard token == generation else { throw CancellationError() }
                busy = false
                if !(error is CancellationError) {
                    wantsPlayback = false
                    await engine.stopEngine()
                    try check(token)
                    phase = .failed(String(describing: error))
                }
                publish()
                throw error
            }
        }
        commandTask = task
        defer { if token == generation { commandTask = nil } }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    private func loadActive(index: Int, position: Double, token: UUID) async throws {
        let id = queue[index]
        currentIndex = index
        phase = .loading(id)
        publish()
        let started = ContinuousClock().now
        let item = try await fetch(index: index, deck: activeDeck, token: token)
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: position)
        try check(token)
        await engine.setGain(1, for: activeDeck)
        try check(token)
        activeFileURL = item.url
        activeMeta = item.meta
        try await applyPlaybackIntent(meta: item.meta, token: token)
        let elapsed = started.duration(to: ContinuousClock().now).components
        // Command-ready latency; not a hardware first-sound measurement.
        firstSoundLatencySeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    private func applyPlaybackIntent(meta: TrackMeta, token: UUID) async throws {
        if wantsPlayback {
            try await engine.play(activeDeck)
            try check(token)
            if !wantsPlayback { await engine.pause(activeDeck); try check(token) }
        }
        phase = wantsPlayback ? .playing(meta) : .paused(meta)
    }
    private func fetch(index: Int, deck: Deck, token: UUID) async throws -> PreparedTrack {
        let id = queue[index]
        async let file = source.localFileURL(for: id)
        async let metadata = source.metadata(for: id)
        let (url, meta) = try await (file, metadata)
        try check(token)
        return PreparedTrack(index: index, deck: deck, url: url, meta: meta)
    }
    private func startPrefetch() {
        guard prepared == nil, prefetchTask == nil, activeMeta != nil,
              let index = currentIndex, index + 1 < queue.count else { return }
        let token = generation
        let deck = otherDeck
        let candidates = Array((index + 1)..<queue.count)
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if token == generation { prefetchTask = nil; publish() } }
            for index in candidates {
                do {
                    let item = try await fetch(index: index, deck: deck, token: token)
                    try await engine.prepare(deck, fileURL: item.url, startTimeSeconds: 0)
                    try check(token)
                    await engine.setGain(0, for: deck)
                    try check(token)
                    prepared = item
                    publish()
                    return
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    lastQueueError = String(describing: error)
                    // Only permanent unavailability is skipped. Authentication/network failures are surfaced once.
                    if let sourceError = error as? TrackSourceError,
                       sourceError == .trackUnavailable || sourceError == .noDownloadOption { continue }
                    publish()
                    return
                }
            }
        }
    }
    private func beginTransition(_ next: PreparedTrack, duration: Double?, token: UUID) {
        waitingForNext = false
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await promote(next, fadeDuration: duration, token: token)
                try check(token)
                transitionTask = nil
                publish()
                startPrefetch()
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                transitionTask = nil
                prepared = nil
                lastQueueError = String(describing: error)
                wantsPlayback = false
                await engine.stopEngine()
                guard token == generation else { return }
                phase = .failed(String(describing: error))
                publish()
            }
        }
        publish()
    }
    private func promote(_ next: PreparedTrack, fadeDuration: Double?, token: UUID) async throws {
        if let fadeDuration {
            try await engine.crossfade(from: activeDeck, to: next.deck, durationSeconds: fadeDuration)
        } else if wantsPlayback {
            try await engine.skip(from: activeDeck, to: next.deck)
        } else {
            await engine.stop(activeDeck)
            try check(token)
            await engine.setGain(1, for: next.deck)
        }
        try check(token)
        activeDeck = next.deck
        activeMeta = next.meta
        activeFileURL = next.url
        currentIndex = next.index
        prepared = nil
        waitingForNext = false
        if !wantsPlayback { await engine.pause(activeDeck); try check(token) }
        phase = wantsPlayback ? .playing(next.meta) : .paused(next.meta)
    }
    private func startMonitor() {
        guard automaticallyMonitor, monitorTask == nil, activeMeta != nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(for: .milliseconds(100)) }
                catch { return }
                guard let self else { return }
                await self.updatePlayback()
            }
        }
    }
    private func deckSnapshot(_ state: AudioEngineSnapshot, _ deck: Deck) -> DeckPlaybackSnapshot {
        deck == .a ? state.deckA : state.deckB
    }
    private func publish() { onChange?(snapshot()) }
}

private struct PreparedTrack: Sendable {
    let index: Int
    let deck: Deck
    let url: URL
    let meta: TrackMeta
}
