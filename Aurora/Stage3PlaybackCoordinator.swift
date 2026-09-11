import AudioEngineCore
import Foundation
import MixModels
import MixPlanner
import PlaybackCoordinator
import TrackSource

@MainActor
final class PlaybackCoordinator {
    private struct Item { let index: Int; let id: TrackID; let url: URL; let meta: TrackMeta; let deck: Deck }
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
    private var effects: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var planSignature = ""
    private var suppressAutoMixUntilTrackChange = false
    private var lastError: String?

    init(source: any TrackSource, engine: DualDeckAudioEngine,
         crossfadeSeconds: Double = 6, automaticallyMonitor: Bool = true) {
        self.source = source; self.engine = engine; _ = crossfadeSeconds
        if automaticallyMonitor { startMonitor() }
    }
    func play(trackID: TrackID) async throws { try await play(queue: [trackID], startIndex: 0) }
    func play(queue: [TrackID], startIndex: Int) async throws {
        guard queue.indices.contains(startIndex) else { throw PlaybackCoordinatorError.noPreparedTrack }
        await cancelTransitionAndWait(); prefetch?.cancel(); await engine.stopEngine()
        ids = queue; index = startIndex; activeDeck = .a; wantsPlayback = true
        suppressAutoMixUntilTrackChange = false
        phase = .loading(queue[startIndex]); publish(); startPrefetch()
        let item = try await fetch(startIndex, deck: activeDeck); active = item
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: 0)
        await engine.setGain(1, for: activeDeck); await engine.setRate(1, for: activeDeck)
        try await engine.play(activeDeck); phase = .playing(item.meta)
        publish(); startPrefetch(); startMonitor()
    }
    func replaceQueue(_ queue: [TrackID]) async throws {
        ids = queue; if let id = active?.id { index = queue.firstIndex(of: id) }
        prefetch?.cancel(); prefetch = nil; prepared = nil
        await engine.stop(otherDeck); startPrefetch(); publish()
    }
    func next() async throws {
        guard !ids.isEmpty else { return }
        await cancelTransitionAndWait()
        if prepared == nil, let pending = prefetch { await pending.value }
        if let item = prepared { try await promote(item, duration: nil, plan: nil); startPrefetch() }
        else { try await load(((index ?? -1) + 1) % ids.count) }
    }
    func previous() async throws {
        guard !ids.isEmpty else { return }
        await cancelTransitionAndWait(); try await load(((index ?? 0) - 1 + ids.count) % ids.count)
    }
    private func load(_ newIndex: Int) async throws {
        prefetch?.cancel(); prefetch = nil
        await engine.stopEngine(); activeDeck = .a; prepared = nil; planSignature = ""
        suppressAutoMixUntilTrackChange = false
        index = newIndex; phase = .loading(ids[newIndex]); publish(); startPrefetch()
        let item = try await fetch(newIndex, deck: activeDeck); active = item
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: 0)
        if wantsPlayback { try await engine.play(activeDeck) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
        publish(); startPrefetch()
    }
    func pause() async {
        wantsPlayback = false; await engine.pause(activeDeck)
        if let item = prepared, transition != nil { await engine.pause(item.deck) }
        if let item = active { phase = .paused(item.meta) }; publish()
    }
    func resume() async throws {
        guard let item = active else { throw PlaybackCoordinatorError.noPreparedTrack }
        wantsPlayback = true; try await engine.resume(activeDeck)
        if let next = prepared, transition != nil { try await engine.resume(next.deck) }
        phase = .playing(item.meta); publish(); startMonitor()
    }
    func seek(to seconds: Double) async throws {
        guard let item = active else { throw PlaybackCoordinatorError.noPreparedTrack }
        await cancelTransitionAndWait(); suppressAutoMixUntilTrackChange = true
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: seconds)
        await engine.setGain(1, for: activeDeck); await engine.setRate(1, for: activeDeck)
        if wantsPlayback { try await engine.play(activeDeck) }
        planSignature = ""; publish()
    }
    func stop() async {
        wantsPlayback = false; await cancelTransitionAndWait(); prefetch?.cancel(); await engine.stopEngine()
        ids = []; index = nil; active = nil; prepared = nil; phase = .idle; publish()
    }
    func handleInterruptionBegan() async { resumeIntent = wantsPlayback; await pause() }
    func handleInterruptionEnded(systemShouldResume: Bool) async throws {
        if resumeIntent && systemShouldResume { try await resume() }
        resumeIntent = false; publish()
    }
    func handleEngineConfigurationChange() async throws {
        let state = await engine.snapshot(); let deck = activeDeck == .a ? state.deckA : state.deckB
        try await seek(to: deck.positionSeconds)
    }
    func snapshot() -> PlaybackCoordinatorSnapshot {
        PlaybackCoordinatorSnapshot(phase: phase, activeDeck: activeDeck,
                                     shouldResumeAfterInterruption: resumeIntent,
                                     firstSoundLatencySeconds: nil, queue: ids, currentIndex: index,
                                     preparedIndex: prepared?.index, isTransitioning: transition != nil,
                                     waitingForNext: prefetch != nil, lastQueueError: lastError)
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
        guard wantsPlayback, transition == nil, let current = active, let currentIndex = index else { return }
        let state = await engine.snapshot(); let deck = activeDeck == .a ? state.deckA : state.deckB

        if prepared == nil {
            guard deck.reachedEndOfFile else { return }
            if let pending = prefetch { await pending.value }
            if let next = prepared {
                try? await promote(next, duration: nil, plan: nil)
                startPrefetch()
            } else if currentIndex + 1 < ids.count {
                do { try await load(currentIndex + 1) }
                catch { lastError = String(describing: error); phase = .failed(lastError ?? "Next track failed"); publish() }
            } else {
                wantsPlayback = false; phase = .ready(current.meta); publish()
            }
            return
        }
        guard let next = prepared else { return }
        if suppressAutoMixUntilTrackChange {
            if deck.reachedEndOfFile { try? await promote(next, duration: nil, plan: nil); startPrefetch() }
            return
        }
        guard let plan = AutoMixV2AnalysisRuntime.shared.transitionPlan else {
            if deck.reachedEndOfFile { try? await promote(next, duration: nil, plan: nil); startPrefetch() }
            return
        }
        if plan.type == .none {
            if deck.reachedEndOfFile { try? await promote(next, duration: nil, plan: nil); startPrefetch() }
            return
        }
        let signature = current.id.raw + "|" + next.id.raw + "|" + plan.type.rawValue + "|" + String(plan.bInStartSec)
        if signature != planSignature {
            do {
                try await engine.prepare(next.deck, fileURL: next.url, startTimeSeconds: plan.bInStartSec)
                await engine.setGain(0, for: next.deck); planSignature = signature
            } catch { lastError = String(describing: error); publish(); return }
        }
        if deck.positionSeconds + 0.010 >= plan.aOutStartSec { begin(next, plan: plan) }
    }
    private func begin(_ item: Item, plan: MixModels.TransitionPlan) {
        transition = Task { @MainActor [weak self] in
            guard let self else { return }
            let duration = plan.type == .crossfade ? plan.bars
                : BeatGridSynchronization.duration(bars: plan.bars, bpm: plan.tempoTargetBPM)
            let outgoing = self.activeDeck
            self.effects = Task { @MainActor [weak self] in
                await self?.executeEffects(plan, outgoing: outgoing, incoming: item.deck, duration: duration)
            }
            do {
                try await self.promote(item, duration: max(0.05, duration), plan: plan)
                // The audio handoff owns the exact transition duration. Never wait
                // indefinitely for an FX observer after the outgoing deck was stopped.
                self.effects?.cancel()
                await self.effects?.value
                self.effects = nil; self.transition = nil
                await self.engine.resetEffects(outgoing); await self.engine.resetEffects(item.deck)
                self.publish(); self.startPrefetch()
            } catch is CancellationError {
                self.effects?.cancel(); await self.effects?.value
                self.effects = nil; self.transition = nil
                await self.engine.resetEffects(outgoing); await self.engine.resetEffects(item.deck)
            } catch {
                self.effects?.cancel(); await self.effects?.value; self.effects = nil
                self.lastError = String(describing: error); self.transition = nil
                await self.engine.resetEffects(outgoing); await self.engine.resetEffects(item.deck); self.publish()
            }
        }; publish()
    }
    private func executeEffects(_ plan: MixModels.TransitionPlan, outgoing: Deck,
                                incoming: Deck, duration: Double) async {
        guard duration.isFinite, duration > 0 else { return }
        let initial = await engine.snapshot()
        let initialDeck = incoming == .a ? initial.deckA : initial.deckB
        let baseline = initialDeck.positionSeconds
        while !Task.isCancelled {
            let state = await engine.snapshot(); let deck = incoming == .a ? state.deckA : state.deckB
            let elapsedSource = max(0, deck.positionSeconds - baseline)
            let elapsedWall = elapsedSource / Double(max(plan.rateB, 0.01))
            if plan.type == .crossfade {
                let p = min(1, max(0, elapsedWall / duration))
                let hp = Float(20 * pow(60, p))
                let lp = Float(2_500 * pow(8, min(1, p * 2)))
                await engine.applyEffect(.highPass, value: hp, param: nil, bpm: 0, to: outgoing)
                await engine.applyEffect(.lowPass, value: lp, param: nil, bpm: 0, to: incoming)
                if p >= 1 { return }
            } else {
                let bar = EffectAutomation.bar(atSeconds: elapsedWall, bpm: plan.tempoTargetBPM)
                for event in plan.fx where event.kind != .volume {
                    if let value = EffectAutomation.value(for: event, atBar: bar) {
                        let target = event.target == .a ? outgoing : incoming
                        await engine.applyEffect(event.kind, value: value, param: event.param,
                                                 bpm: plan.tempoTargetBPM, to: target)
                    }
                }
                if bar >= plan.bars { return }
            }
            do { try await ContinuousClock().sleep(for: .milliseconds(10)) } catch { return }
        }
    }
    private func promote(_ item: Item, duration: Double?, plan: MixModels.TransitionPlan?) async throws {
        if let plan, !plan.fx.contains(where: { $0.kind == .rateRamp }) {
            await engine.setRate(plan.rateA, for: activeDeck); await engine.setRate(plan.rateB, for: item.deck)
        }
        if let duration { try await engine.crossfade(from: activeDeck, to: item.deck, durationSeconds: duration) }
        else if wantsPlayback { try await engine.skip(from: activeDeck, to: item.deck) }
        activeDeck = item.deck; active = item; index = item.index; prepared = nil; planSignature = ""
        suppressAutoMixUntilTrackChange = false
        if !wantsPlayback { await engine.pause(activeDeck) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
    }
    private func cancelTransitionAndWait() async {
        effects?.cancel(); let fx = effects; effects = nil
        let task = transition; transition = nil; task?.cancel()
        await task?.value; await fx?.value
        await engine.resetEffects(.a); await engine.resetEffects(.b)
    }
    private func startPrefetch() {
        guard prepared == nil, prefetch == nil, let index, index + 1 < ids.count else { return }
        let deck = otherDeck
        prefetch = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.prefetch = nil; self.publish() }
            do {
                let item = try await self.fetch(index + 1, deck: deck)
                try await self.engine.prepare(deck, fileURL: item.url, startTimeSeconds: 0)
                await self.engine.setGain(0, for: deck); self.prepared = item
            } catch is CancellationError { return }
            catch { self.lastError = String(describing: error) }
        }
    }
    private func fetch(_ index: Int, deck: Deck) async throws -> Item {
        let id = ids[index]; async let url = source.localFileURL(for: id); async let meta = source.metadata(for: id)
        return try await Item(index: index, id: id, url: url, meta: meta, deck: deck)
    }
    private var otherDeck: Deck { activeDeck == .a ? .b : .a }
    private func publish() { onChange?(snapshot()) }
}
