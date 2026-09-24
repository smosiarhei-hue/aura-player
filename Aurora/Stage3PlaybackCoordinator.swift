import AudioEngineCore
import Foundation
import MixModels
import MixPlanner
import PlaybackCoordinator
import QuartzCore
import TrackSource

@MainActor
final class PlaybackCoordinator {
    enum TransitionReadiness: String, Sendable {
        case idle, waitingForDeckB, waitingForAnalysis, ready, transitioning, fallback, ended, failed
    }

    private struct Item {
        let index: Int
        let id: TrackID
        let url: URL
        let meta: TrackMeta
        let deck: Deck
    }

    private let source: any TrackSource
    private let engine: DualDeckAudioEngine
    private let fallbackCrossfadeSeconds: Double
    var onChange: (@MainActor @Sendable (PlaybackCoordinatorSnapshot) -> Void)?

    private var phase: PlaybackPhase = .idle
    private var ids: [TrackID] = []
    private var index: Int?
    private var active: Item?
    private var prepared: Item?
    private var transitioningItem: Item?
    private var activeDeck: Deck = .a
    private var wantsPlayback = false
    private var resumeIntent = false
    private var monitor: Task<Void, Never>?
    private var transition: Task<Void, Never>?
    private var effects: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    private var planSignature = ""
    private var lastError: String?
    private(set) var transitionReadiness: TransitionReadiness = .idle
    private(set) var transitionReason = "Ожидание воспроизведения"
    private(set) var transitionStartHostTime: Double?
    private(set) var transitionDuration: Double?

    var transitionProgress: Double? {
        guard transition != nil, let start = transitionStartHostTime,
              let duration = transitionDuration, duration > 0 else { return nil }
        return min(1, max(0, (CACurrentMediaTime() - start) / duration))
    }

    init(source: any TrackSource, engine: DualDeckAudioEngine,
         crossfadeSeconds: Double = 6, automaticallyMonitor: Bool = true) {
        self.source = source
        self.engine = engine
        fallbackCrossfadeSeconds = min(12, max(0.75, crossfadeSeconds.isFinite ? crossfadeSeconds : 6))
        if automaticallyMonitor { startMonitor() }
    }

    func applyUserEQ(gains: [Float], enabled: Bool) {
        engine.applyUserEQ(gains: gains, enabled: enabled)
    }

    func play(trackID: TrackID) async throws {
        try await play(queue: [trackID], startIndex: 0)
    }

    func play(queue: [TrackID], startIndex: Int) async throws {
        guard queue.indices.contains(startIndex) else { throw PlaybackCoordinatorError.noPreparedTrack }
        await cancelTransitionAndWait()
        prefetch?.cancel()
        prefetch = nil
        phase = .loading(queue[startIndex])
        setReadiness(.waitingForDeckB, "Загрузка композиции")
        publish()

        let item = try await fetch(startIndex, deck: .a, queue: queue)
        try Task.checkCancellation()
        await engine.stopEngine()
        ids = queue
        index = startIndex
        activeDeck = .a
        active = item
        prepared = nil
        wantsPlayback = true
        planSignature = ""
        try await engine.prepare(.a, fileURL: item.url, startTimeSeconds: 0)
        await engine.setGain(1, for: .a)
        await engine.setRate(1, for: .a)
        try await engine.play(.a)
        phase = .playing(item.meta)
        publish()
        startPrefetch()
        startMonitor()
    }

    func replaceQueue(_ queue: [TrackID]) async throws {
        ids = queue
        if let id = active?.id { index = queue.firstIndex(of: id) }
        prefetch?.cancel()
        prefetch = nil
        prepared = nil
        await engine.stop(otherDeck)
        setReadiness(.waitingForDeckB, "Очередь обновлена; готовится следующий трек")
        startPrefetch()
        publish()
    }

    func appendQueue(_ additional: [TrackID]) async throws {
        guard !additional.isEmpty else { return }
        ids.append(contentsOf: additional)
        if prepared == nil { startPrefetch() }
        publish()
    }

    func next() async throws {
        guard let currentIndex = index, !ids.isEmpty else { return }

        if transition != nil, let incoming = transitioningItem {
            let outgoing = incoming.deck == activeDeck ? otherDeck : activeDeck
            await cancelTransitionAndWait()
            await engine.setGain(1, for: incoming.deck)
            await engine.setRate(1, for: incoming.deck)
            await engine.resetEffects(incoming.deck)
            if wantsPlayback {
                try await engine.skip(from: outgoing, to: incoming.deck)
            } else {
                await engine.stop(outgoing)
                await engine.pause(incoming.deck)
            }
            commitHandoff(to: incoming)
            setReadiness(.waitingForDeckB, "Трек переключён")
            publish()
            startPrefetch()
            return
        }

        guard currentIndex + 1 < ids.count else { return }
        await cancelTransitionAndWait()

        if let item = prepared, item.index > currentIndex {
            try await promotePrepared(item)
            return
        }

        phase = .loading(ids[currentIndex + 1])
        publish()
        if let pending = prefetch {
            await pending.value
            if let item = prepared, item.index > currentIndex {
                try await promotePrepared(item)
                return
            }
        }
        try await load(currentIndex + 1)
    }

    private func promotePrepared(_ item: Item) async throws {
        try await engine.prepare(item.deck, fileURL: item.url, startTimeSeconds: 0)
        await engine.setGain(1, for: item.deck)
        await engine.setRate(1, for: item.deck)
        await engine.resetEffects(item.deck)
        try await promote(item, duration: nil, plan: nil)
        publish()
        startPrefetch()
    }

    func previous() async throws {
        guard !ids.isEmpty else { return }
        if transition != nil {
            let outgoing = activeDeck
            let incomingDeck = transitioningItem?.deck
            await cancelTransitionAndWait()
            if let incomingDeck, incomingDeck != outgoing { await engine.stop(incomingDeck) }
            await engine.setGain(1, for: outgoing)
            await engine.setRate(1, for: outgoing)
            await engine.resetEffects(outgoing)
            if let active { phase = wantsPlayback ? .playing(active.meta) : .paused(active.meta) }
            setReadiness(.waitingForDeckB, "Переход отменён")
            publish()
            startPrefetch()
            return
        }
        guard let currentIndex = index, currentIndex > 0 else {
            try await seek(to: 0)
            return
        }
        try await load(currentIndex - 1)
    }

    private func load(_ newIndex: Int) async throws {
        guard ids.indices.contains(newIndex) else { throw PlaybackCoordinatorError.noPreparedTrack }
        prefetch?.cancel()
        prefetch = nil
        phase = .loading(ids[newIndex])
        setReadiness(.waitingForDeckB, "Загрузка следующей композиции")
        publish()

        let item = try await fetch(newIndex, deck: .a)
        try Task.checkCancellation()
        await engine.stopEngine()
        activeDeck = .a
        active = item
        index = newIndex
        prepared = nil
        planSignature = ""
        try await engine.prepare(.a, fileURL: item.url, startTimeSeconds: 0)
        await engine.setGain(1, for: .a)
        await engine.setRate(1, for: .a)
        if wantsPlayback { try await engine.play(.a) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
        publish()
        startPrefetch()
    }

    func pause() async {
        wantsPlayback = false
        if transition != nil {
            let outgoing = activeDeck
            let incomingDeck = transitioningItem?.deck
            await cancelTransitionAndWait()
            if let incomingDeck, incomingDeck != outgoing { await engine.stop(incomingDeck) }
            await engine.setGain(1, for: outgoing)
        }
        await engine.pause(.a)
        await engine.pause(.b)
        if let active { phase = .paused(active.meta) }
        publish()
    }

    func resume() async throws {
        guard let item = active else { throw PlaybackCoordinatorError.noPreparedTrack }
        wantsPlayback = true
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        if !deck.isPrepared {
            try await engine.prepare(activeDeck, fileURL: item.url,
                                     startTimeSeconds: max(0, deck.positionSeconds))
            await engine.setGain(1, for: activeDeck)
            await engine.setRate(1, for: activeDeck)
            await engine.resetEffects(activeDeck)
        }
        try await engine.resume(activeDeck)
        phase = .playing(item.meta)
        publish()
        startMonitor()
    }

    func seek(to seconds: Double) async throws {
        guard let item = active else { throw PlaybackCoordinatorError.noPreparedTrack }
        await cancelTransitionAndWait()
        try await engine.prepare(activeDeck, fileURL: item.url, startTimeSeconds: seconds)
        await engine.setGain(1, for: activeDeck)
        await engine.setRate(1, for: activeDeck)
        if wantsPlayback { try await engine.play(activeDeck) }
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
        planSignature = ""
        setReadiness(prepared == nil ? .waitingForDeckB : .waitingForAnalysis,
                     "Перемотка завершена; AutoMix снова активен")
        publish()
    }

    func stop() async {
        wantsPlayback = false
        await cancelTransitionAndWait()
        prefetch?.cancel()
        prefetch = nil
        await engine.stopEngine()
        ids = []
        index = nil
        active = nil
        prepared = nil
        phase = .idle
        setReadiness(.idle, "Воспроизведение остановлено")
        publish()
    }

    func handleInterruptionBegan() async { resumeIntent = wantsPlayback; await pause() }
    func handleInterruptionEnded(systemShouldResume: Bool) async throws {
        if resumeIntent && systemShouldResume { try await resume() }
        resumeIntent = false
        publish()
    }
    func handleEngineConfigurationChange() async throws {
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        try await seek(to: deck.positionSeconds)
    }

    func snapshot() -> PlaybackCoordinatorSnapshot {
        PlaybackCoordinatorSnapshot(
            phase: phase, activeDeck: activeDeck,
            shouldResumeAfterInterruption: resumeIntent,
            firstSoundLatencySeconds: nil, queue: ids, currentIndex: index,
            preparedIndex: transitioningItem?.index ?? prepared?.index,
            isTransitioning: transition != nil, waitingForNext: prefetch != nil,
            lastQueueError: lastError)
    }

    func engineSnapshot() async -> AudioEngineSnapshot { await engine.snapshot() }
    func updatePlayback() async { await tick() }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(for: .milliseconds(100)) }
                catch { return }
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard wantsPlayback, transition == nil,
              let current = active, let currentIndex = index else { return }
        let state = await engine.snapshot()
        let deck = activeDeck == .a ? state.deckA : state.deckB
        let hasNext = currentIndex + 1 < ids.count

        if prepared == nil {
            setReadiness(hasNext ? .waitingForDeckB : .ended,
                         hasNext ? "Deck B ещё загружается" : "Это последний трек очереди")
            guard deck.reachedEndOfFile else { return }
            if let pending = prefetch { await pending.value }
            if let next = prepared {
                try? await promote(next, duration: nil, plan: nil)
                publish()
                startPrefetch()
            } else if hasNext {
                do { try await load(currentIndex + 1) }
                catch {
                    lastError = String(describing: error)
                    phase = .failed(lastError ?? "Next track failed")
                    setReadiness(.failed, lastError ?? "Ошибка следующего трека")
                    publish()
                }
            } else {
                wantsPlayback = false
                phase = .ready(current.meta)
                setReadiness(.ended, "Очередь завершена")
                publish()
            }
            return
        }

        guard let next = prepared else { return }
        let analysis = AutoMixV2AnalysisRuntime.shared
        let plan = analysis.plan(for: current.id, nextID: next.id)
        let usablePlan = plan.flatMap { $0.type == .none ? nil : $0 }
        let duration = deck.durationSeconds ?? current.meta.durationSec
        let remaining = max(0, duration - deck.positionSeconds)
        let reachedPlanStart = usablePlan.map { $0.aOutStartSec - deck.positionSeconds <= 0.30 } ?? false
        let decision = AutoMixTransitionGate.decide(
            hasNext: hasNext, nextPrepared: true, reachedEnd: deck.reachedEndOfFile,
            remainingSeconds: remaining, hasUsablePlan: usablePlan != nil,
            reachedPlannedStart: reachedPlanStart, fallbackSeconds: fallbackCrossfadeSeconds)

        switch decision {
        case .waitingForNext:
            setReadiness(.waitingForDeckB, "Deck B ещё загружается")
        case .waitingForPlan:
            setReadiness(.waitingForAnalysis, analysis.status(for: current.id, nextID: next.id))
        case .readyForPlan:
            guard let plan = usablePlan else { return }
            await preparePlanIfNeeded(plan, current: current, next: next)
        case .startPlanned:
            guard let plan = usablePlan else { return }
            if await preparePlanIfNeeded(plan, current: current, next: next) {
                begin(next, plan: plan)
            } else {
                beginFallback(next, duration: min(fallbackCrossfadeSeconds, max(0.75, remaining)))
            }
        case .startFallback(let seconds):
            beginFallback(next, duration: seconds)
        case .hardCutAtEnd:
            do {
                try await promote(next, duration: nil, plan: nil)
                publish()
                startPrefetch()
            } catch {
                lastError = String(describing: error)
                setReadiness(.failed, lastError ?? "Ошибка переключения")
                publish()
            }
        case .queueEnded:
            wantsPlayback = false
            phase = .ready(current.meta)
            setReadiness(.ended, "Очередь завершена")
            publish()
        }
    }

    @discardableResult
    private func preparePlanIfNeeded(_ plan: MixModels.TransitionPlan,
                                     current: Item, next: Item) async -> Bool {
        let signature = current.id.raw + "|" + next.id.raw + "|" +
            plan.type.rawValue + "|" + String(plan.bInStartSec)
        if signature != planSignature {
            do {
                try await engine.prepare(next.deck, fileURL: next.url,
                                         startTimeSeconds: plan.bInStartSec)
                await engine.setGain(0, for: next.deck)
                await engine.setRate(plan.rateB, for: next.deck)
                if plan.pitchShiftCentsB != 0 {
                    await engine.setPitch(plan.pitchShiftCentsB, for: next.deck)
                }
                planSignature = signature
            } catch {
                lastError = String(describing: error)
                setReadiness(.failed, lastError ?? "Ошибка подготовки Deck B")
                publish()
                return false
            }
        }
        setReadiness(.ready, "Музыкальный план готов: \(plan.type.rawValue)")
        return true
    }

    private func beginFallback(_ item: Item, duration: Double) {
        let duration = max(0.75, duration)
        let plan = MixModels.TransitionPlan(
            type: .crossfade, archetype: .energyWash, aOutStartSec: 0, bInStartSec: 0,
            bars: duration, tempoTargetBPM: 0, rateA: 1, rateB: 1,
            pitchShiftCentsB: 0,
            gainOffsetBdB: 0, loopBarsA: 0, fx: [], reason: "DJ Filter Fallback")
        launchTransition(item, plan: plan, duration: duration,
                         readiness: .fallback,
                         reason: "Выполняется резервный DJ-переход")
    }

    private func begin(_ item: Item, plan: MixModels.TransitionPlan) {
        let duration = plan.tempoTargetBPM > 0
            ? BeatGridSynchronization.duration(bars: plan.bars, bpm: plan.tempoTargetBPM)
            : plan.bars
        launchTransition(item, plan: plan, duration: max(0.05, duration),
                         readiness: .transitioning,
                         reason: "Выполняется \(plan.type.rawValue)")
    }

    private func launchTransition(_ item: Item, plan: MixModels.TransitionPlan,
                                  duration: Double, readiness: TransitionReadiness,
                                  reason: String) {
        guard transition == nil else { return }
        transitioningItem = item
        transitionStartHostTime = CACurrentMediaTime()
        transitionDuration = duration
        setReadiness(readiness, reason)
        transition = Task { @MainActor [weak self] in
            guard let self else { return }
            let outgoing = self.activeDeck
            let incoming = item.deck
            let start = CACurrentMediaTime()
            let audio = self.engine
            self.effects = Task.detached(priority: .userInteractive) {
                await Self.executeEffectsDetached(plan: plan, engine: audio,
                                                  outgoing: outgoing, incoming: incoming,
                                                  duration: duration, startHostTime: start)
            }
            do {
                try await self.promote(item, duration: duration, plan: plan)
                self.effects?.cancel()
                await self.effects?.value
                self.finishTransition(outgoing: outgoing, incoming: item.deck)
                self.publish()
                self.startPrefetch()
            } catch is CancellationError {
                self.effects?.cancel()
                await self.effects?.value
                self.finishCancelledTransition(outgoing: outgoing, incoming: item.deck)
            } catch {
                self.effects?.cancel()
                await self.effects?.value
                self.lastError = String(describing: error)
                self.finishCancelledTransition(outgoing: outgoing, incoming: item.deck)
                self.setReadiness(.failed, self.lastError ?? "Ошибка перехода")
                self.publish()
            }
        }
        publish()
    }

    private func finishTransition(outgoing: Deck, incoming: Deck) {
        effects = nil
        transition = nil
        transitioningItem = nil
        transitionStartHostTime = nil
        transitionDuration = nil
        // Outgoing delay spillover is actively ringing out and will self-neutralize
        // in DualDeckAudioEngine.startDelaySpillover. We do NOT immediately neutralize here.
    }

    private func finishCancelledTransition(outgoing: Deck, incoming: Deck) {
        effects = nil
        transition = nil
        transitioningItem = nil
        transitionStartHostTime = nil
        transitionDuration = nil
        Task { @MainActor in
            await engine.resetEffects(outgoing)
            await engine.resetEffects(incoming)
        }
    }

    private nonisolated static func executeEffectsDetached(
        plan: MixModels.TransitionPlan,
        engine: DualDeckAudioEngine,
        outgoing: Deck,
        incoming: Deck,
        duration: Double,
        startHostTime: Double
    ) async {
        guard duration.isFinite, duration > 0 else { return }
        while !Task.isCancelled {
            let now = CACurrentMediaTime()
            if now < startHostTime {
                do { try await ContinuousClock().sleep(for: .milliseconds(5)) }
                catch { return }
                continue
            }
            let elapsed = max(0, now - startHostTime)
            if plan.fx.isEmpty {
                let p = min(1, elapsed / duration)
                await engine.applyEffect(.highPass, value: Float(20 * pow(225, p)),
                                         param: nil, bpm: 0, to: outgoing)
                await engine.applyEffect(.lowPass,
                                         value: Float(1_500 * pow(13.33, min(1, p * 1.8))),
                                         param: nil, bpm: 0, to: incoming)
                await engine.applyEffect(.bassKill,
                                         value: Float(min(1, max(0, (p - 0.2) / 0.3))),
                                         param: nil, bpm: 0, to: outgoing)
                await engine.applyEffect(.bassKill,
                                         value: Float(min(1, max(0, 1 - (p - 0.5) / 0.3))),
                                         param: nil, bpm: 0, to: incoming)
                if p >= 0.5 {
                    await engine.applyEffect(.echoOut, value: Float(55 * (p - 0.5) / 0.5),
                                             param: 45, bpm: 120, to: outgoing)
                }
                if p >= 1 { return }
            } else {
                let bar = EffectAutomation.bar(atSeconds: elapsed, bpm: plan.tempoTargetBPM)
                for event in plan.fx {
                    if let value = EffectAutomation.value(for: event, atBar: bar) {
                        await engine.applyEffect(event.kind, value: value, param: event.param,
                                                 bpm: plan.tempoTargetBPM,
                                                 to: event.target == .a ? outgoing : incoming)
                    }
                }
                if bar >= plan.bars { return }
            }
            do { try await ContinuousClock().sleep(for: .milliseconds(10)) }
            catch { return }
        }
    }

    private func promote(_ item: Item, duration: Double?,
                         plan: MixModels.TransitionPlan?) async throws {
        let outgoing = activeDeck
        if let plan {
            await engine.setRate(plan.rateA, for: outgoing)
            await engine.setRate(plan.rateB, for: item.deck)
            if plan.pitchShiftCentsB != 0 {
                await engine.setPitch(plan.pitchShiftCentsB, for: item.deck)
            }
        }
        if let duration {
            if let plan, plan.type != .crossfade {
                try await engine.crossfade(from: outgoing, to: item.deck,
                                           durationSeconds: duration,
                                           alignedToCueSeconds: plan.aOutStartSec)
            } else {
                try await engine.crossfade(from: outgoing, to: item.deck,
                                           durationSeconds: duration)
            }
        } else if wantsPlayback {
            try await engine.skip(from: outgoing, to: item.deck)
        }

        commitHandoff(to: item)
        if let plan {
            if plan.rateB != 1 {
                let tempo = plan.tempoTargetBPM > 0 ? plan.tempoTargetBPM / plan.rateB : 120
                let seconds = BeatGridSynchronization.duration(bars: 4, bpm: tempo)
                await engine.rampRate(item.deck, from: plan.rateB, to: 1,
                                      duration: seconds > 0 ? seconds : 3)
            }
            if plan.pitchShiftCentsB != 0 {
                let deck = item.deck
                let cents = plan.pitchShiftCentsB
                let audio = engine
                Task.detached(priority: .userInitiated) {
                    await audio.rampPitch(deck, from: cents, to: 0, duration: 8.0)
                }
            }
        }
        if !wantsPlayback { await engine.pause(item.deck) }
        setReadiness(.waitingForDeckB, "Готовится следующий трек")
    }

    private func commitHandoff(to item: Item) {
        activeDeck = item.deck
        active = item
        index = item.index
        prepared = nil
        planSignature = ""
        phase = wantsPlayback ? .playing(item.meta) : .paused(item.meta)
    }

    private func cancelTransitionAndWait() async {
        transitionStartHostTime = nil
        transitionDuration = nil
        effects?.cancel()
        let fx = effects
        effects = nil
        let task = transition
        transition = nil
        task?.cancel()
        await task?.value
        await fx?.value
        transitioningItem = nil
        await engine.resetEffects(.a)
        await engine.resetEffects(.b)
    }

    private func startPrefetch() {
        guard prepared == nil, prefetch == nil,
              let currentIndex = index, currentIndex + 1 < ids.count else { return }
        let deck = otherDeck
        let queue = ids
        setReadiness(.waitingForDeckB, "Загрузка и подготовка Deck B")
        prefetch = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.prefetch = nil; self.publish() }
            var candidate = currentIndex + 1
            while candidate < queue.count, !Task.isCancelled {
                do {
                    let item = try await self.fetch(candidate, deck: deck, queue: queue)
                    try Task.checkCancellation()
                    try await self.engine.prepare(deck, fileURL: item.url, startTimeSeconds: 0)
                    await self.engine.setGain(0, for: deck)
                    self.prepared = item
                    self.setReadiness(.waitingForAnalysis,
                                      "Deck B готова; ожидается музыкальный план")
                    return
                } catch TrackSourceError.trackUnavailable {
                    candidate += 1
                } catch TrackSourceError.noDownloadOption {
                    candidate += 1
                } catch is CancellationError {
                    return
                } catch {
                    self.lastError = String(describing: error)
                    self.setReadiness(.failed, self.lastError ?? "Ошибка подготовки Deck B")
                    return
                }
            }
        }
    }

    private func fetch(_ index: Int, deck: Deck, queue: [TrackID]? = nil) async throws -> Item {
        let queue = queue ?? ids
        guard queue.indices.contains(index) else { throw PlaybackCoordinatorError.noPreparedTrack }
        let id = queue[index]
        async let url = source.localFileURL(for: id)
        async let meta = source.metadata(for: id)
        return try await Item(index: index, id: id, url: url, meta: meta, deck: deck)
    }

    private func setReadiness(_ value: TransitionReadiness, _ reason: String) {
        guard transitionReadiness != value || transitionReason != reason else { return }
        transitionReadiness = value
        transitionReason = reason
    }

    private var otherDeck: Deck { activeDeck == .a ? .b : .a }
    private func publish() { onChange?(snapshot()) }
}
