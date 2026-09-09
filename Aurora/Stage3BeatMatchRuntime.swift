// Path: Aurora/Stage3BeatMatchRuntime.swift

@preconcurrency import AVFAudio
import AudioEngineCore
import Foundation
import MixDiagnostics
import MixModels
import PlaybackCoordinator
import TrackSource

/// App composition-root engine for Stage 3. The package Stage 1 engine remains
/// available to its low-level streaming tests; the app resolves this local type.
@MainActor
final class DualDeckAudioEngine {
    private final class Slot: @unchecked Sendable {
        let deck: Deck
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let mixer = AVAudioMixerNode()
        var file: AVAudioFile?
        var url: URL?
        var start = 0.0
        var duration = 0.0
        var rate: Float = 1
        var prepared = false
        var playing = false
        var ended = false
        init(_ deck: Deck) { self.deck = deck }
    }

    private let graph = AVAudioEngine()
    private let a = Slot(.a)
    private let b = Slot(.b)

    init() throws {
        for slot in [a, b] {
            graph.attach(slot.player)
            graph.attach(slot.timePitch)
            graph.attach(slot.mixer)
            graph.connect(slot.player, to: slot.timePitch, format: nil)
            graph.connect(slot.timePitch, to: slot.mixer, format: nil)
            graph.connect(slot.mixer, to: graph.mainMixerNode, format: nil)
            slot.timePitch.pitch = 0
            slot.timePitch.rate = 1
            slot.timePitch.overlap = 8
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
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { throw AudioEngineCoreError.unsupportedOutputFormat }
        let duration = Double(file.length) / sampleRate
        let start = min(max(0, startTimeSeconds), max(0, duration - 1 / sampleRate))
        let firstFrame = AVAudioFramePosition(start * sampleRate)
        let remaining = max(1, file.length - firstFrame)
        let frameCount = AVAudioFrameCount(min(Int64(UInt32.max), remaining))
        slot.file = file
        slot.url = fileURL
        slot.start = start
        slot.duration = duration
        slot.prepared = true
        slot.playing = false
        slot.ended = false
        slot.player.scheduleSegment(file, startingFrame: firstFrame, frameCount: frameCount, at: nil) { [weak slot] in
            Task { @MainActor in
                slot?.playing = false
                slot?.ended = true
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

    func pause(_ deck: Deck) async { slot(deck).player.pause(); slot(deck).playing = false }
    func resume(_ deck: Deck) async throws { try await play(deck) }

    func stop(_ deck: Deck) async {
        let slot = slot(deck)
        slot.player.stop()
        slot.player.reset()
        slot.file = nil
        slot.url = nil
        slot.start = 0
        slot.duration = 0
        slot.rate = 1
        slot.timePitch.rate = 1
        slot.prepared = false
        slot.playing = false
        slot.ended = false
    }

    func stopEngine() async {
        await stop(.a)
        await stop(.b)
        graph.stop()
    }

    func setGain(_ gain: Float, for deck: Deck) async {
        slot(deck).mixer.outputVolume = min(1, max(0, gain.isFinite ? gain : 0))
    }

    func setRate(_ rate: Float, for deck: Deck) async {
        let value = min(1.08, max(0.92, rate.isFinite ? rate : 1))
        slot(deck).rate = value
        slot(deck).timePitch.rate = value
    }

    func skip(from current: Deck, to next: Deck) async throws {
        try await play(next)
        await setGain(1, for: next)
        await stop(current)
    }

    func crossfade(from outgoing: Deck, to incoming: Deck, durationSeconds: Double) async throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw AudioEngineCoreError.conversionFailed("Invalid transition duration")
        }
        try await play(incoming)
        let started = ContinuousClock().now
        while true {
            try Task.checkCancellation()
            let elapsed = started.duration(to: ContinuousClock().now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let progress = min(1, max(0, seconds / durationSeconds))
            slot(outgoing).mixer.outputVolume = Float(cos(progress * .pi / 2))
            slot(incoming).mixer.outputVolume = Float(sin(progress * .pi / 2))
            if progress >= 1 { break }
            try await ContinuousClock().sleep(for: .milliseconds(5))
        }
        await stop(outgoing)
        await setGain(1, for: incoming)
    }

    func snapshot() async -> AudioEngineSnapshot {
        let format = graph.outputNode.outputFormat(forBus: 0)
        return AudioEngineSnapshot(isRunning: graph.isRunning,
                                   sampleRate: format.sampleRate,
                                   channels: format.channelCount,
                                   deckA: snapshot(a), deckB: snapshot(b))
    }

    private func snapshot(_ slot: Slot) -> DeckPlaybackSnapshot {
        let played: Double
        if let render = slot.player.lastRenderTime,
           let time = slot.player.playerTime(forNodeTime: render), time.sampleRate > 0 {
            played = Double(time.sampleTime) / time.sampleRate * Double(slot.rate)
        } else { played = 0 }
        let position = slot.ended ? slot.duration : min(slot.duration, slot.start + max(0, played))
        return DeckPlaybackSnapshot(deck: slot.deck, fileURL: slot.url,
                                    isPrepared: slot.prepared, isPlaying: slot.playing,
                                    gain: slot.mixer.outputVolume,
                                    queuedChunks: slot.prepared && !slot.ended ? 1 : 0,
                                    reachedEndOfFile: slot.ended,
                                    positionSeconds: position,
                                    durationSeconds: slot.prepared ? slot.duration : nil)
    }

    private func slot(_ deck: Deck) -> Slot { deck == .a ? a : b }
}

/// Executes the current Stage 3 TransitionPlan with independent deck rates.
@MainActor
final class PlaybackCoordinator {
    private struct Item {
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
    private var ids: [TrackID] = []
    private var index: Int?
    private var active: Item?
    private var prepared: Item?
    private var activeDeck: Deck = .a
    private var wantsPlayback = false
    private var resumeIntent = false
    private var monitor: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var planSignature = ""
    private var lastError: String?

    init(source: any TrackSource, engine: DualDeckAudioEngine,
         crossfadeSeconds: Double = 6, automaticallyMonitor: Bool = true) {
        self.source = source
        self.engine = engine
        _ = crossfadeSeconds
        if automaticallyMonitor { startMonitor() }
    }

    func play(trackID: TrackID) async throws { try await play(queue: [trackID], startIndex: 0) }

    func play(queue: [TrackID], startIndex: Int) async throws {
        guard queue.indices.contains(startIndex) else { throw PlaybackCoordinatorError.noPreparedTrack }
        transition?.cancel(); prefetch?.cancel(); await engine.stopEngine()
        ids = queue; index = startIndex; activeDeck = .a; wantsPlayback = true
        phase = .loading(queue[startIndex]); publish()
        let item = try await fetch(startIndex, deck: activeDeck)
        active = item
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: 0)
        await engine.setGain(1, for: activeDeck)
        await engine.setRate(1, for: activeDeck)
        try await engine.play(activeDeck)
        phase = .playing(item.meta); publish(); startPrefetch(); startMonitor()
    }

    func replaceQueue(_ queue: [TrackID]) async throws {
        ids = queue
        if let id = active?.id { index = queue.firstIndex(of: id) }
        prepared = nil
        await engine.stop(otherDeck)
        startPrefetch(); publish()
    }

    func next() async throws {
        guard !ids.isEmpty else { return }
        transition?.cancel(); prefetch?.cancel()
        if let item = prepared { try await promote(item, duration: nil, plan: nil) }
        else { try await load(((index ?? -1) + 1) % ids.count) }
    }

    func previous() async throws {
        guard !ids.isEmpty else { return }
        try await load(((index ?? 0) - 1 + ids.count) % ids.count)
    }

    private func load(_ newIndex: Int) async throws {
        await engine.stopEngine(); activeDeck = .a; prepared = nil; planSignature = ""
        let item = try await fetch(newIndex, deck: activeDeck)
        active = item; index = newIndex
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: 0)
        if wantsPlayback { try await engine.play(activeDeck) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
        publish(); startPrefetch()
    }

    func pause() async {
        wantsPlayback = false
        await engine.pause(activeDeck)
        if let item = prepared, transition != nil { await engine.pause(item.deck) }
        if let item = active { phase = .paused(item.meta) }
        publish()
    }

    func resume() async throws {
        guard let item = active else { throw PlaybackCoordinatorError.noPreparedTrack }
        wantsPlayback = true
        try await engine.resume(activeDeck)
        if let next = prepared, transition != nil { try await engine.resume(next.deck) }
        phase = .playing(item.meta); publish(); startMonitor()
    }

    func seek(to seconds: Double) async throws {
        guard let item = active else { throw PlaybackCoordinatorError.noPreparedTrack }
        transition?.cancel(); transition = nil
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: seconds)
        await engine.setRate(1, for: activeDeck)
        if wantsPlayback { try await engine.play(activeDeck) }
        prepared = nil; planSignature = ""; startPrefetch(); publish()
    }

    func stop() async {
        wantsPlayback = false; transition?.cancel(); prefetch?.cancel()
        await engine.stopEngine()
        ids = []; index = nil; active = nil; prepared = nil; phase = .idle; publish()
    }

    func handleInterruptionBegan() async { resumeIntent = wantsPlayback; await pause() }
    func handleInterruptionEnded(systemShouldResume: Bool) async throws {
        if resumeIntent && systemShouldResume { try await resume() }
        resumeIntent = false; publish()
    }
    func handleEngineConfigurationChange() async throws {
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        try await seek(to: deck.positionSeconds)
    }

    func snapshot() -> PlaybackCoordinatorSnapshot {
        PlaybackCoordinatorSnapshot(phase: phase, activeDeck: activeDeck,
                                    shouldResumeAfterInterruption: resumeIntent,
                                    firstSoundLatencySeconds: nil, queue: ids,
                                    currentIndex: index, preparedIndex: prepared?.index,
                                    isTransitioning: transition != nil,
                                    waitingForNext: prefetch != nil,
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
        guard wantsPlayback, transition == nil, let current = active, let next = prepared else { return }
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        guard let plan = AutoMixV2AnalysisRuntime.shared.transitionPlan else {
            if deck.reachedEndOfFile { try? await promote(next, duration: nil, plan: nil) }
            return
        }
        if plan.type == .none {
            if deck.reachedEndOfFile { try? await promote(next, duration: nil, plan: nil) }
            return
        }
        let signature = current.id.raw + "|" + next.id.raw + "|" + plan.type.rawValue + "|" + String(plan.bInStartSec)
        if signature != planSignature {
            do {
                try await engine.prepare(next.deck, fileURL: next.url, startTimeSeconds: plan.bInStartSec)
                await engine.setGain(0, for: next.deck)
                planSignature = signature
            } catch { lastError = String(describing: error); publish(); return }
        }
        if deck.positionSeconds + 0.010 >= plan.aOutStartSec { begin(next, plan: plan) }
    }

    private func begin(_ item: Item, plan: TransitionPlan) {
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
        activeDeck = item.deck; active = item; index = item.index; prepared = nil; planSignature = ""
        if !wantsPlayback { await engine.pause(activeDeck) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
    }

    private func startPrefetch() {
        guard prepared == nil, prefetch == nil, let index, index + 1 < ids.count else { return }
        let deck = otherDeck
        prefetch = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { prefetch = nil; publish() }
            do {
                let item = try await fetch(index + 1, deck: deck)
                try await engine.prepare(deck, fileURL: item.url, startTimeSeconds: 0)
                await engine.setGain(0, for: deck)
                prepared = item
            } catch { lastError = String(describing: error) }
        }
    }

    private func fetch(_ index: Int, deck: Deck) async throws -> Item {
        let id = ids[index]
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
        let type = plan?.type.rawValue ?? "none"
        return [
            "Stage 3 beatmatch executor",
            "phase=\(state.phase)",
            "deck=\(state.activeDeck.rawValue)",
            String(format: "position=%.3f", active.positionSeconds),
            "transition=\(state.isTransitioning)",
            "type=\(type)",
            String(format: "targetBPM=%.2f", plan?.tempoTargetBPM ?? 0),
            String(format: "rateA=%.5f rateB=%.5f", plan?.rateA ?? 1, plan?.rateB ?? 1)
        ].joined(separator: "\n")
    }
}
