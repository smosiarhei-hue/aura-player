// Path: Aurora/Stage3BeatMatchRuntime.swift

@preconcurrency import AVFAudio
import AudioEngineCore
import Foundation
import MixDiagnostics
import MixModels
import PlaybackCoordinator
import TrackSource

/// App-local Stage 3 engine. The local name intentionally replaces the Stage 1
/// engine at the app composition root while the package implementation remains
/// available to the lower-level streaming tests.
@MainActor
final class DualDeckAudioEngine {
    private final class Slot {
        let deck: Deck
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let mixer = AVAudioMixerNode()
        var file: AVAudioFile?
        var fileURL: URL?
        var startSec = 0.0
        var durationSec = 0.0
        var rate: Float = 1
        var prepared = false
        var playing = false
        var completed = false
        var error: String?

        init(_ deck: Deck) { self.deck = deck }
    }

    private let graph = AVAudioEngine()
    private let a = Slot(.a)
    private let b = Slot(.b)
    private var fadeTask: Task<Void, Error>?

    init() throws {
        for slot in [a, b] {
            graph.attach(slot.player)
            graph.attach(slot.timePitch)
            graph.attach(slot.mixer)
            graph.connect(slot.player, to: slot.timePitch, format: nil)
            graph.connect(slot.timePitch, to: slot.mixer, format: nil)
            graph.connect(slot.mixer, to: graph.mainMixerNode, format: nil)
            slot.timePitch.overlap = 8
            slot.timePitch.pitch = 0
        }
        a.mixer.outputVolume = 1
        b.mixer.outputVolume = 0
        graph.prepare()
    }

    func prepare(_ deck: Deck, fileURL: URL, startTimeSeconds: Double = 0) async throws {
        try Task.checkCancellation()
        let slot = slot(deck)
        slot.player.stop()
        slot.player.reset()
        let file = try AVAudioFile(forReading: fileURL)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw AudioEngineCoreError.unsupportedOutputFormat }
        let duration = Double(file.length) / rate
        let start = min(max(0, startTimeSeconds), max(0, duration - 1 / rate))
        let frame = AVAudioFramePosition(start * rate)
        let count64 = max(1, file.length - frame)
        let count = AVAudioFrameCount(min(Int64(UInt32.max), count64))
        slot.file = file
        slot.fileURL = fileURL
        slot.startSec = start
        slot.durationSec = duration
        slot.prepared = true
        slot.playing = false
        slot.completed = false
        slot.error = nil
        slot.player.scheduleSegment(file, startingFrame: frame, frameCount: count, at: nil) { [weak slot] in
            Task { @MainActor in
                slot?.playing = false
                slot?.completed = true
            }
        }
    }

    func play(_ deck: Deck) async throws {
        let slot = slot(deck)
        guard slot.prepared else { throw AudioEngineCoreError.deckNotPrepared(deck) }
        if !graph.isRunning { try graph.start() }
        slot.player.play()
        slot.playing = true
    }

    func pause(_ deck: Deck) async {
        let slot = slot(deck)
        slot.player.pause()
        slot.playing = false
    }

    func resume(_ deck: Deck) async throws { try await play(deck) }

    func stop(_ deck: Deck) async {
        let slot = slot(deck)
        slot.player.stop()
        slot.player.reset()
        slot.file = nil
        slot.fileURL = nil
        slot.prepared = false
        slot.playing = false
        slot.completed = false
        slot.startSec = 0
        slot.durationSec = 0
        slot.rate = 1
        slot.timePitch.rate = 1
    }

    func stopEngine() async {
        fadeTask?.cancel()
        fadeTask = nil
        await stop(.a)
        await stop(.b)
        graph.stop()
    }

    func setGain(_ gain: Float, for deck: Deck) async {
        slot(deck).mixer.outputVolume = min(1, max(0, gain.isFinite ? gain : 0))
    }

    func setRate(_ rate: Float, for deck: Deck) async {
        let safe = min(1.08, max(0.92, rate.isFinite ? rate : 1))
        let slot = slot(deck)
        slot.rate = safe
        slot.timePitch.rate = safe
    }

    func skip(from current: Deck, to next: Deck) async throws {
        fadeTask?.cancel()
        try await play(next)
        await setGain(1, for: next)
        await stop(current)
    }

    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw AudioEngineCoreError.conversionFailed("Invalid Stage 3 transition duration")
        }
        guard slot(outgoing).prepared, slot(incoming).prepared else {
            throw AudioEngineCoreError.deckNotPrepared(incoming)
        }
        try await play(incoming)
        let start = ContinuousClock().now
        while true {
            try Task.checkCancellation()
            let elapsed = start.duration(to: ContinuousClock().now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let progress = min(1, max(0, seconds / durationSeconds))
            let gains = CrossfadeCurve.gains(progress: progress)
            slot(outgoing).mixer.outputVolume = gains.outgoing
            slot(incoming).mixer.outputVolume = gains.incoming
            if progress >= 1 { break }
            try await ContinuousClock().sleep(for: .milliseconds(5))
        }
        await stop(outgoing)
        await setGain(1, for: incoming)
    }

    func snapshot() async -> AudioEngineSnapshot {
        AudioEngineSnapshot(isRunning: graph.isRunning,
                            sampleRate: graph.outputNode.outputFormat(forBus: 0).sampleRate,
                            channels: graph.outputNode.outputFormat(forBus: 0).channelCount,
                            deckA: snapshot(a), deckB: snapshot(b))
    }

    private func snapshot(_ slot: Slot) -> DeckPlaybackSnapshot {
        let rendered: Double
        if let renderTime = slot.player.lastRenderTime,
           let time = slot.player.playerTime(forNodeTime: renderTime), time.sampleRate > 0 {
            rendered = Double(time.sampleTime) / time.sampleRate * Double(slot.rate)
        } else { rendered = 0 }
        let position = slot.completed ? slot.durationSec : min(slot.durationSec, slot.startSec + max(0, rendered))
        return DeckPlaybackSnapshot(deck: slot.deck, fileURL: slot.fileURL,
                                    isPrepared: slot.prepared, isPlaying: slot.playing,
                                    gain: slot.mixer.outputVolume,
                                    queuedChunks: slot.prepared && !slot.completed ? 1 : 0,
                                    reachedEndOfFile: slot.completed, lastError: slot.error,
                                    positionSeconds: position, durationSeconds: slot.prepared ? slot.durationSec : nil)
    }

    private func slot(_ deck: Deck) -> Slot { deck == .a ? a : b }
}

/// Stage 3 coordinator consumes the live TransitionPlan produced by the Stage 2/3
/// analysis runtime and executes it against two independently rate-controlled decks.
@MainActor
final class PlaybackCoordinator {
    struct Item {
        let index: Int
        let id: TrackID
        let url: URL
        let meta: TrackMeta
        let deck: Deck
    }

    private let source: any TrackSource
    private let engine: DualDeckAudioEngine
    var onChange: (@MainActor @Sendable (PlaybackCoordinatorSnapshot) -> Void)?
    private var phase: PlaybackPhase = .idle
    private var queue: [TrackID] = []
    private var currentIndex: Int?
    private var active: Item?
    private var prepared: Item?
    private var activeDeck: Deck = .a
    private var wantsPlayback = false
    private var resumeAfterInterruption = false
    private var monitor: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var configuredPlanSignature = ""
    private var lastError: String?

    init(source: any TrackSource, engine: DualDeckAudioEngine,
         crossfadeSeconds: Double = 6, automaticallyMonitor: Bool = true) {
        self.source = source
        self.engine = engine
        if automaticallyMonitor { startMonitor() }
        _ = crossfadeSeconds
    }

    deinit { monitor?.cancel(); transition?.cancel(); preparation?.cancel() }

    func play(trackID: TrackID) async throws { try await play(queue: [trackID], startIndex: 0) }

    func play(queue: [TrackID], startIndex: Int) async throws {
        guard queue.indices.contains(startIndex) else { throw PlaybackCoordinatorError.noPreparedTrack }
        transition?.cancel(); preparation?.cancel()
        await engine.stopEngine()
        self.queue = queue
        currentIndex = startIndex
        activeDeck = .a
        wantsPlayback = true
        phase = .loading(queue[startIndex]); publish()
        active = try await fetch(index: startIndex, deck: activeDeck)
        guard let active else { throw PlaybackCoordinatorError.noPreparedTrack }
        try await engine.prepare(activeDeck, fileURL: active.url, startTimeSeconds: 0)
        await engine.setGain(1, for: activeDeck)
        try await engine.setRate(1, for: activeDeck)
        try await engine.play(activeDeck)
        phase = .playing(active.meta); publish()
        startPrefetch()
        startMonitor()
    }

    func replaceQueue(_ newQueue: [TrackID]) async throws {
        queue = newQueue
        if let id = active?.id { currentIndex = newQueue.firstIndex(of: id) }
        prepared = nil
        await engine.stop(otherDeck)
        startPrefetch(); publish()
    }

    func next() async throws {
        guard !queue.isEmpty else { return }
        transition?.cancel(); preparation?.cancel()
        if let prepared { try await promote(prepared, duration: nil, plan: nil) }
        else {
            let nextIndex = ((currentIndex ?? -1) + 1) % queue.count
            await engine.stopEngine()
            activeDeck = .a
            active = try await fetch(index: nextIndex, deck: activeDeck)
            guard let active else { throw PlaybackCoordinatorError.noPreparedTrack }
            try await engine.prepare(activeDeck, fileURL: active.url, startTimeSeconds: 0)
            if wantsPlayback { try await engine.play(activeDeck) }
            currentIndex = nextIndex
            phase = wantsPlayback ? .playing(active.meta) : .paused(active.meta)
            startPrefetch(); publish()
        }
    }

    func previous() async throws {
        guard !queue.isEmpty else { return }
        let index = ((currentIndex ?? 0) - 1 + queue.count) % queue.count
        await engine.stopEngine(); activeDeck = .a
        active = try await fetch(index: index, deck: activeDeck)
        guard let active else { throw PlaybackCoordinatorError.noPreparedTrack }
        try await engine.prepare(activeDeck, fileURL: active.url, startTimeSeconds: 0)
        if wantsPlayback { try await engine.play(activeDeck) }
        currentIndex = index; prepared = nil
        phase = wantsPlayback ? .playing(active.meta) : .paused(active.meta)
        startPrefetch(); publish()
    }

    func pause() async {
        wantsPlayback = false
        await engine.pause(activeDeck)
        if let prepared, transition != nil { await engine.pause(prepared.deck) }
        if let active { phase = .paused(active.meta) }
        publish()
    }

    func resume() async throws {
        guard let active else { throw PlaybackCoordinatorError.noPreparedTrack }
        wantsPlayback = true
        try await engine.resume(activeDeck)
        if let prepared, transition != nil { try await engine.resume(prepared.deck) }
        phase = .playing(active.meta); publish(); startMonitor()
    }

    func seek(to seconds: Double) async throws {
        guard let active else { throw PlaybackCoordinatorError.noPreparedTrack }
        transition?.cancel(); transition = nil
        try await engine.prepare(activeDeck, fileURL: active.url, startTimeSeconds: seconds)
        await engine.setRate(1, for: activeDeck)
        if wantsPlayback { try await engine.play(activeDeck) }
        prepared = nil; configuredPlanSignature = ""; startPrefetch(); publish()
    }

    func stop() async {
        wantsPlayback = false; transition?.cancel(); preparation?.cancel()
        await engine.stopEngine()
        queue = []; currentIndex = nil; active = nil; prepared = nil
        phase = .idle; publish()
    }

    func handleInterruptionBegan() async { resumeAfterInterruption = wantsPlayback; await pause() }
    func handleInterruptionEnded(systemShouldResume: Bool) async throws {
        if resumeAfterInterruption && systemShouldResume { try await resume() }
        resumeAfterInterruption = false; publish()
    }
    func handleEngineConfigurationChange() async throws {
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        try await seek(to: deck.positionSeconds)
    }

    func snapshot() -> PlaybackCoordinatorSnapshot {
        PlaybackCoordinatorSnapshot(phase: phase, activeDeck: activeDeck,
                                    shouldResumeAfterInterruption: resumeAfterInterruption,
                                    firstSoundLatencySeconds: nil, queue: queue,
                                    currentIndex: currentIndex, preparedIndex: prepared?.index,
                                    isTransitioning: transition != nil, waitingForNext: preparation != nil,
                                    lastQueueError: lastError)
    }
    func engineSnapshot() async -> AudioEngineSnapshot { await engine.snapshot() }
    func updatePlayback() async { await tick() }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(for: .milliseconds(20)) } catch { return }
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard wantsPlayback, transition == nil, let active, let prepared else { return }
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        let plan = AutoMixV2AnalysisRuntime.shared.transitionPlan
        if let plan, plan.type != .none {
            let signature = "\(active.id.raw)|\(prepared.id.raw)|\(plan.type.rawValue)|\(plan.bInStartSec)"
            if signature != configuredPlanSignature {
                configuredPlanSignature = signature
                do {
                    try await engine.prepare(prepared.deck, fileURL: prepared.url, startTimeSeconds: plan.bInStartSec)
                    await engine.setGain(0, for: prepared.deck)
                } catch { lastError = String(describing: error); publish(); return }
            }
            if deck.positionSeconds + 0.010 >= plan.aOutStartSec {
                beginTransition(prepared, plan: plan)
            }
        } else if deck.reachedEndOfFile {
            do { try await promote(prepared, duration: nil, plan: nil) }
            catch { lastError = String(describing: error); publish() }
        }
        _ = active
    }

    private func beginTransition(_ item: Item, plan: TransitionPlan) {
        transition = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let duration = plan.type == .crossfade
                    ? plan.bars : BeatGridSynchronization.duration(bars: plan.bars, bpm: plan.tempoTargetBPM)
                try await promote(item, duration: max(0.05, duration), plan: plan)
                transition = nil; publish(); startPrefetch()
            } catch is CancellationError { transition = nil }
            catch { lastError = String(describing: error); transition = nil; publish() }
        }
        publish()
    }

    private func promote(_ item: Item, duration: Double?, plan: TransitionPlan?) async throws {
        if let plan {
            await engine.setRate(plan.rateA, for: activeDeck)
            await engine.setRate(plan.rateB, for: item.deck)
        }
        if let duration { try await engine.crossfade(from: activeDeck, to: item.deck, durationSeconds: duration) }
        else if wantsPlayback { try await engine.skip(from: activeDeck, to: item.deck) }
        activeDeck = item.deck; active = item; currentIndex = item.index; prepared = nil
        configuredPlanSignature = ""
        if !wantsPlayback { await engine.pause(activeDeck) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
    }

    private func startPrefetch() {
        guard prepared == nil, preparation == nil, let index = currentIndex,
              index + 1 < queue.count else { return }
        let deck = otherDeck
        preparation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { preparation = nil; publish() }
            do {
                let item = try await fetch(index: index + 1, deck: deck)
                try await engine.prepare(deck, fileURL: item.url, startTimeSeconds: 0)
                await engine.setGain(0, for: deck)
                prepared = item
            } catch { lastError = String(describing: error) }
        }
    }

    private func fetch(index: Int, deck: Deck) async throws -> Item {
        let id = queue[index]
        async let url = source.localFileURL(for: id)
        async let meta = source.metadata(for: id)
        return try await Item(index: index, id: id, url: url, meta: meta, deck: deck)
    }

    private var otherDeck: Deck { activeDeck == .a ? .b : .a }
    private func publish() { onChange?(snapshot()) }
}

extension MixDiagnosticsStore {
    func textReport(coordinator: PlaybackCoordinator) async -> String {
        let state = await coordinator.snapshot()
        let engine = await coordinator.engineSnapshot()
        let active = state.activeDeck == .a ? engine.deckA : engine.deckB
        let plan = await MainActor.run { AutoMixV2AnalysisRuntime.shared.transitionPlan }
        return [
            "Stage 3 beatmatch executor",
            "phase=\(state.phase)",
            "deck=\(state.activeDeck.rawValue)",
            String(format: "position=%.3f", active.positionSeconds),
            "transition=\(state.isTransitioning)",
            "type=\(plan?.type.rawValue ?? \"none\")",
            String(format: "targetBPM=%.2f", plan?.tempoTargetBPM ?? 0),
            String(format: "rateA=%.5f rateB=%.5f", plan?.rateA ?? 1, plan?.rateB ?? 1)
        ].joined(separator: "\n")
    }
}
