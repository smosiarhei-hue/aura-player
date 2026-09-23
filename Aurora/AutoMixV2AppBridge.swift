// Path: Aurora/AutoMixV2AppBridge.swift

@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import AudioEngineCore
import MixDiagnostics
import MixModels
import NeuroMixEngine
import Observation
import PlaybackCoordinator
import TrackAnalysis
import TrackSource

enum PlaybackOwner: String, Sendable {
    case legacy
    case autoMixV2
    case neuroMix
}

@Observable
@MainActor
final class AutoMixEngineSelectionStore {
    static let shared = AutoMixEngineSelectionStore()
    static let defaultsKey = "automix.v2.enabled"
    static let neuroDefaultsKey = "neuromix.enabled"
    private var isUpdatingSelection = false
    var isV2Enabled: Bool {
        didSet {
            UserDefaults.standard.set(isV2Enabled, forKey: Self.defaultsKey)
            guard !isUpdatingSelection else { return }
            if isV2Enabled && isNeuroEnabled {
                isUpdatingSelection = true
                isNeuroEnabled = false
                isUpdatingSelection = false
            }
            PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            PlaybackCommandRouter.shared.selectionChanged()
        }
    }
    var isNeuroEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isNeuroEnabled, forKey: Self.neuroDefaultsKey)
            guard !isUpdatingSelection else { return }
            if isNeuroEnabled && isV2Enabled {
                isUpdatingSelection = true
                isV2Enabled = false
                isUpdatingSelection = false
            }
            PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            PlaybackCommandRouter.shared.selectionChanged()
        }
    }
    private init() {
        UserDefaults.standard.register(defaults: [Self.defaultsKey: true, Self.neuroDefaultsKey: false])
        let neuroEnabled = UserDefaults.standard.bool(forKey: Self.neuroDefaultsKey)
        isNeuroEnabled = neuroEnabled
        isV2Enabled = neuroEnabled ? false : UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

}

@Observable
@MainActor
final class NeuroMixRuntime {
    static let shared = NeuroMixRuntime()
    private let source = LocalTrackSource()
    private let analyzer: TrackAnalyzer
    private let yandexClient = AutoMixV2YandexDownloadClient()
    private let yandexSource: YandexTrackSource?
    private var engine: DualDeckAudioEngine?
    private var queue: [Track] = []
    private var resolvedURLs: [UUID: URL] = [:]
    private var currentIndex: Int?
    private var activeDeck: Deck = .a
    private var monitorTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var activeTransitionID: UUID?
    private var profileWarmTask: Task<Void, Never>?
    private(set) var currentTrack: Track?
    private(set) var isPlaying = false
    private(set) var lastError: String?
    private(set) var pipelineStatus = "Ожидание воспроизведения"
    private(set) var currentProfile: TrackProfile?
    private(set) var nextProfile: TrackProfile?
    private(set) var transitionPlan: NeuroTransitionPlan?
    var playbackQueue: [Track] { queue }

    private init() {
        let directory = (try? TrackAnalyzer.defaultStorageDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("neuromix-profiles", isDirectory: true)
        analyzer = TrackAnalyzer(storageDirectory: directory)
        if let cache = try? TrackFileCache(directory: TrackFileCache.defaultDirectory()) {
            yandexSource = YandexTrackSource(client: yandexClient, cache: cache, maximumParallelDownloads: 2)
        } else {
            yandexSource = nil
        }
    }

    func engineSelectionChanged(isEnabled: Bool) async {
        if !isEnabled { await stop() }
    }

    func play(_ track: Track, queue newQueue: [Track]) async -> Bool {
        do {
            try await stop()
            queue = newQueue
            if !queue.contains(where: { $0.id == track.id }) { queue.insert(track, at: 0) }
            let firstURL = try await resolveURL(for: track)
            guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return false }
            currentIndex = index
            currentTrack = track
            activeDeck = .a
            let audio = try DualDeckAudioEngine()
            engine = audio
            await audio.applyUserEQ(gains: PlayerCore.shared.eqGains, enabled: PlayerCore.shared.eqEnabled)
            try await audio.prepare(.a, fileURL: firstURL)
            await audio.setGain(1, for: .a)
            try await audio.play(.a)
            isPlaying = true
            pipelineStatus = "Анализ текущего трека"
            startMonitoring()
            warmProfiles(startingAt: index)
            return true
        } catch {
            lastError = String(describing: error)
            await stop()
            return false
        }
    }

    func play() async -> Bool {
        guard let engine else { return false }
        do {
            try await engine.resume(activeDeck)
            isPlaying = true
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    func pause() async {
        await engine?.pause(activeDeck)
        isPlaying = false
    }

    func next() async {
        guard let currentIndex, currentIndex + 1 < queue.count else { return }
        await manualSwitch(to: currentIndex + 1)
    }

    func previous() async {
        guard let currentIndex else { return }
        if currentIndex > 0 {
            await manualSwitch(to: currentIndex - 1)
        } else {
            try? await engine?.seek(activeDeck, to: 0)
        }
    }

    func replaceQueue(_ newQueue: [Track]) {
        queue = newQueue
    }

    func replaceUpcomingQueue(with tracks: [Track]) {
        if let current = currentTrack {
            var newQ = [current]
            var seen = Set([current.id])
            for t in tracks where seen.insert(t.id).inserted {
                newQ.append(t)
            }
            queue = newQ
        } else {
            queue = tracks
        }
    }

    func appendQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let existing = Set(queue.map(\.id))
        queue.append(contentsOf: tracks.filter { !existing.contains($0.id) })
    }

    private func manualSwitch(to nextIndex: Int) async {
        guard queue.indices.contains(nextIndex), let engine else { return }
        let wasPlaying = isPlaying
        let pending = transitionTask
        transitionTask = nil
        activeTransitionID = nil
        pending?.cancel()
        await pending?.value

        do {
            let nextTrack = queue[nextIndex]
            let nextURL = try await resolveURL(for: nextTrack)
            let incomingDeck: Deck = activeDeck == .a ? .b : .a
            try await engine.prepare(incomingDeck, fileURL: nextURL, startTimeSeconds: 0)
            if wasPlaying {
                try await engine.skip(from: activeDeck, to: incomingDeck)
            } else {
                await engine.stop(activeDeck)
                await engine.setGain(1, for: incomingDeck)
            }
            activeDeck = incomingDeck
            currentIndex = nextIndex
            currentTrack = nextTrack
            currentProfile = nil
            nextProfile = nil
            transitionPlan = nil
            pipelineStatus = "Ручное переключение"
            startMonitoring()
            warmProfiles(startingAt: nextIndex)
        } catch is CancellationError {
            return
        } catch {
            lastError = String(describing: error)
            pipelineStatus = "Ошибка ручного переключения"
        }
    }

    func seek(to seconds: Double) async {
        try? await engine?.seek(activeDeck, to: seconds)
    }

    func engineConfigurationChanged() async {
        let position = await engine?.snapshot()
        let deck = activeDeck == .a ? position?.deckA : position?.deckB
        if let seconds = deck?.positionSeconds { try? await engine?.seek(activeDeck, to: seconds) }
    }

    func stop() async {
        monitorTask?.cancel()
        let transition = transitionTask
        transitionTask = nil
        activeTransitionID = nil
        transition?.cancel()
        await transition?.value
        profileWarmTask?.cancel()
        monitorTask = nil
        await engine?.stopEngine()
        engine = nil
        currentIndex = nil
        currentTrack = nil
        isPlaying = false
        pipelineStatus = "Ожидание воспроизведения"
        currentProfile = nil
        nextProfile = nil
        transitionPlan = nil
    }

    func calculatePlan() async {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            pipelineStatus = "Ожидание воспроизведения"
            return
        }

        guard currentIndex + 1 < queue.count else {
            pipelineStatus = "Следующего локального трека нет"
            transitionPlan = nil
            return
        }
        let current = queue[currentIndex]
        let next = queue[currentIndex + 1]
        do {
            pipelineStatus = "Анализ текущего трека"
            let currentProfile = try await analyzer.profile(
                for: TrackID(raw: current.id.uuidString), fileURL: try await resolveURL(for: current))
            guard !Task.isCancelled else { return }
            pipelineStatus = "Анализ следующего трека"
            let nextProfile = try await analyzer.profile(
                for: TrackID(raw: next.id.uuidString), fileURL: try await resolveURL(for: next))
            guard !Task.isCancelled else { return }
            self.currentProfile = currentProfile
            self.nextProfile = nextProfile
            transitionPlan = NeuroMixPlanningRuntime.shared.plan(from: currentProfile, to: nextProfile)
            pipelineStatus = "План NeuroMix готов"
        } catch {
            lastError = String(describing: error)
            pipelineStatus = "Ошибка анализа NeuroMix"
        }
    }

    func playbackTimeline() async -> (position: Double, duration: Double, isTransitioning: Bool, transitionProgress: Double)? {
        guard let engine, currentTrack != nil else { return nil }
        let snapshot = await engine.snapshot()
        let deck = activeDeck == .a ? snapshot.deckA : snapshot.deckB
        let duration = deck.durationSeconds ?? currentTrack?.duration ?? 0
        return (
            max(0, deck.positionSeconds),
            duration.isFinite ? max(0, duration) : 0,
            transitionTask != nil,
            transitionTask == nil ? 0 : 0.5
        )
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await ContinuousClock().sleep(for: .milliseconds(250))
                await self?.monitor()
            }
        }
    }

    private func monitor() async {
        guard transitionTask == nil, isPlaying, let currentIndex,
              currentIndex + 1 < queue.count, let engine else { return }
        let snapshot = await engine.snapshot()
        let deck = activeDeck == .a ? snapshot.deckA : snapshot.deckB
        let duration = deck.durationSeconds ?? queue[currentIndex].duration
        guard duration.isFinite, duration > 0,
              deck.positionSeconds.isFinite, deck.positionSeconds >= 0 else { return }
        let remaining = max(0, duration - deck.positionSeconds)
        if remaining <= 30 { await transition(to: currentIndex + 1, force: false) }
    }

    private func warmProfiles(startingAt index: Int) {
        profileWarmTask?.cancel()
        guard queue.indices.contains(index) else { return }
        let ids = [index, index + 1].filter { queue.indices.contains($0) }
        let tracks = ids.map { queue[$0] }
        profileWarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for track in tracks {
                guard !Task.isCancelled else { return }
                if let url = try? await self.resolveURL(for: track) {
                    _ = try? await self.analyzer.profile(
                        for: TrackID(raw: track.id.uuidString), fileURL: url)
                }
            }
        }
    }

    private func resolveURL(for track: Track) async throws -> URL {
        if let cached = resolvedURLs[track.id] { return cached }
        if !track.isStream, track.url.isFileURL {
            resolvedURLs[track.id] = track.url
            return track.url
        }
        guard let raw = track.streamUrlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              let source = yandexSource else {
            throw TrackSourceError.noDownloadOption
        }
        let id = YandexMusicService.ymId(fromFileName: track.fileName) ?? raw
        let trackID = TrackID(raw: id)
        await yandexClient.register(TrackMeta(
            id: trackID, title: track.title, artist: track.artist,
            albumID: track.album.isEmpty ? nil : track.album,
            durationSec: track.duration,
            artworkURL: track.coverURL.flatMap(URL.init(string:))))
        let url = try await source.localFileURL(for: trackID)
        resolvedURLs[track.id] = url
        return url
    }

    private func transition(to nextIndex: Int, force: Bool) async {
        transitionTask?.cancel()
        await transitionTask?.value
        guard let engine, queue.indices.contains(nextIndex), let currentIndex,
              let current = currentTrack else { return }
        let transitionID = UUID()
        activeTransitionID = transitionID
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sourceProfile = try await self.analyzer.profile(
                    for: TrackID(raw: current.id.uuidString), fileURL: try await self.resolveURL(for: current))
                let targetTrack = self.queue[nextIndex]
                let targetProfile = try await self.analyzer.profile(
                    for: TrackID(raw: targetTrack.id.uuidString), fileURL: try await self.resolveURL(for: targetTrack))
                guard !Task.isCancelled, self.activeTransitionID == transitionID else { return }
                let plan = NeuroMixPlanningRuntime.shared.plan(from: sourceProfile, to: targetProfile)
                self.currentProfile = sourceProfile
                self.nextProfile = targetProfile
                self.transitionPlan = plan
                self.pipelineStatus = "DJ-переход: \(plan.kind.rawValue)"
                let incomingDeck: Deck = self.activeDeck == .a ? .b : .a
                if !force {
                    while !Task.isCancelled, self.activeTransitionID == transitionID {
                        let snapshot = await engine.snapshot()
                        let outgoing = self.activeDeck == .a ? snapshot.deckA : snapshot.deckB
                        guard outgoing.positionSeconds < plan.sourceStartSeconds else { break }
                        try await ContinuousClock().sleep(for: .milliseconds(100))
                    }
                }
                guard !Task.isCancelled, self.activeTransitionID == transitionID else { return }
                let runner = NeuroMixRealtimeTransitionRunner(engine: engine)
                try await runner.execute(plan, incomingURL: try await self.resolveURL(for: targetTrack),
                                          targetBPM: Double(targetProfile.bpm),
                                          outgoing: self.activeDeck, incoming: incomingDeck)
                guard !Task.isCancelled, self.activeTransitionID == transitionID else { return }
                self.activeDeck = incomingDeck
                self.currentIndex = nextIndex
                self.currentTrack = targetTrack
                self.pipelineStatus = "Переход завершён"
                if self.activeTransitionID == transitionID {
                    self.activeTransitionID = nil
                    self.transitionTask = nil
                }
            } catch is CancellationError {
                if self.activeTransitionID == transitionID {
                    self.activeTransitionID = nil
                    self.transitionTask = nil
                }
            } catch {
                guard self.activeTransitionID == transitionID else { return }
                self.lastError = String(describing: error)
                self.pipelineStatus = "Ошибка перехода NeuroMix"
                if force { self.isPlaying = false }
                self.activeTransitionID = nil
                self.transitionTask = nil
            }
        }
        await transitionTask?.value
    }
}

@Observable
@MainActor
final class AutoMixV2Runtime {
    static let shared = AutoMixV2Runtime()
    private let localSource: LocalTrackSource
    private let yandexClient: AutoMixV2YandexDownloadClient
    private let compositeSource: CompositeTrackSource?
    private var coordinator: PlaybackCoordinator?
    let diagnostics = MixDiagnosticsStore()
    private var queue: [Track] = []
    private var queueIDs: [TrackID] = []
    private var requestID = UUID()
    private var queueUpdateTask: Task<Void, Never>?
    private(set) var currentTrack: Track?
    private(set) var currentCodec: String?
    private(set) var currentBitrate: Int?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var diagnosticReport = "Нажмите «Обновить отчёт»."

    private init() {
        let local = LocalTrackSource(); let client = AutoMixV2YandexDownloadClient()
        localSource = local; yandexClient = client
        var builtComposite: CompositeTrackSource?; var startupError: String?
        do {
            let cache = try TrackFileCache(directory: TrackFileCache.defaultDirectory())
            let yandex = YandexTrackSource(client: client, cache: cache, maximumParallelDownloads: 2)
            let composite = CompositeTrackSource(localSource: local, yandexSource: yandex)
            builtComposite = composite
        } catch {
            builtComposite = nil
            startupError = String(describing: error)
        }
        compositeSource = builtComposite
        coordinator = nil
        lastError = startupError
    }
    private func ensureCoordinator() -> PlaybackCoordinator? {
        if let coordinator { return coordinator }
        guard let compositeSource else {
            lastError = lastError ?? "AutoMix V2 source недоступен"
            return nil
        }
        do {
            let engine = try DualDeckAudioEngine()
            let builtCoordinator = PlaybackCoordinator(source: compositeSource, engine: engine)
            builtCoordinator.applyUserEQ(
                gains: PlayerCore.shared.eqGains,
                enabled: PlayerCore.shared.eqEnabled
            )
            builtCoordinator.onChange = { [weak self] state in self?.apply(state) }
            coordinator = builtCoordinator
            lastError = nil
            return builtCoordinator
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }
    func applyUserEQ(gains: [Float], enabled: Bool) { coordinator?.applyUserEQ(gains: gains, enabled: enabled) }
    func engineSelectionChanged(isV2Enabled: Bool) async { if isV2Enabled { await adoptLegacyTrackIfNeeded() } else { await stop() } }
    func adoptLegacyTrackIfNeeded() async {
        guard currentTrack == nil, let track = PlayerCore.shared.currentTrack else { return }
        await play(track, queue: PlayerCore.shared.queue)
    }
    func replaceQueue(_ newQueue: [Track]) {
        let token = beginRequest()
        queueUpdateTask = Task { [weak self] in
            guard let self, let coordinator else { return }
            do {
                let registered = try await register(newQueue, token: token); try check(token)
                queue = registered.tracks; queueIDs = registered.ids
                try await coordinator.replaceQueue(registered.ids); try check(token); apply(coordinator.snapshot())
            } catch is CancellationError { return }
            catch { guard token == requestID else { return }; lastError = Self.userMessage(for: error) }
        }
    }
    func appendQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let coordinator else {
            queue.append(contentsOf: tracks)
            return
        }
        let token = beginRequest()
        queueUpdateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let registered = try await self.register(tracks, token: token)
                try self.check(token)
                self.queue.append(contentsOf: registered.tracks)
                self.queueIDs.append(contentsOf: registered.ids)
                try await coordinator.appendQueue(registered.ids)
                try self.check(token)
                self.apply(coordinator.snapshot())
            } catch is CancellationError {
                return
            } catch {
                guard token == self.requestID else { return }
                self.lastError = Self.userMessage(for: error)
            }
        }
    }
    @discardableResult
    func play(_ track: Track, queue newQueue: [Track]) async -> Bool {
        guard let coordinator = ensureCoordinator() else {
            lastError = lastError ?? "AutoMix V2 audio engine недоступен"
            return false
        }
        let token = beginRequest(); isLoading = true; lastError = nil
        var tracks = newQueue.isEmpty ? [track] : newQueue
        if !tracks.contains(where: { $0.id == track.id }) { tracks.insert(track, at: 0) }
        do {
            let registered = try await register(tracks, token: token); try check(token)
            guard let index = registered.tracks.firstIndex(where: { $0.id == track.id }) else { throw TrackSourceError.invalidTrackID }
            queue = registered.tracks; queueIDs = registered.ids; PlayerCore.shared.stopAndClear()
            try await coordinator.play(queue: registered.ids, startIndex: index); try check(token)
            apply(coordinator.snapshot())
            await diagnostics.record(MixDiagnosticEvent(category: "playback", message: "Queue playback started"))
        } catch is CancellationError { return false }
        catch {
            guard token == requestID else { return false }
            await fail(Self.userMessage(for: error), category: "playback")
            return false
        }
        return true
    }
    @discardableResult
    func play() async -> Bool {
        if currentTrack == nil {
            await adoptLegacyTrackIfNeeded()
            return currentTrack != nil
        }
        guard let coordinator = ensureCoordinator() else { return false }
        do {
            try await coordinator.resume()
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastError = Self.userMessage(for: error)
            return false
        }
    }
    func pause() async { await coordinator?.pause() }
    func stop() async {
        let token = beginRequest(); await coordinator?.stop(); guard token == requestID else { return }
        isPlaying = false; isLoading = false; currentTrack = nil; queue = []; queueIDs = []
    }
    func toggle() async {
        if isPlaying {
            await pause()
        } else {
            _ = await play()
        }
    }
    func next() async {
        if queue.count <= 1 {
            refillQueueIfNeeded()
            await waitForNextTrack()
        }
        guard queue.count > 1 else { return }
        if let index = coordinator?.snapshot().currentIndex, index >= queue.count - 2 {
            refillQueueIfNeeded()
        }
        await runCommand { try await $0.next() }
    }
    func previous() async {
        guard queue.count > 1 else {
            await seek(to: 0)
            return
        }
        await runCommand { try await $0.previous() }
    }
    func seek(to seconds: Double) async { await runCommand { try await $0.seek(to: seconds) } }
    private func runCommand(_ command: @escaping @MainActor (PlaybackCoordinator) async throws -> Void) async {
        guard let coordinator else { return }; let token = beginRequest()
        do { try await command(coordinator) }
        catch is CancellationError { return }
        catch { if token == requestID { lastError = Self.userMessage(for: error) } }
    }
    func interruptionBegan() async { await coordinator?.handleInterruptionBegan() }
    func interruptionEnded(shouldResume: Bool) async {
        guard let coordinator else { return }
        do { try await coordinator.handleInterruptionEnded(systemShouldResume: shouldResume) }
        catch is CancellationError { return } catch { lastError = Self.userMessage(for: error) }
    }
    func engineConfigurationChanged() async {
        guard let coordinator else { return }
        do { try await coordinator.handleEngineConfigurationChange() }
        catch is CancellationError { return } catch { lastError = Self.userMessage(for: error) }
    }
    func refreshDiagnostics() async {
        guard let coordinator else { diagnosticReport = lastError ?? "AutoMix V2 audio engine недоступен"; return }
        diagnosticReport = await diagnostics.textReport(coordinator: coordinator)
    }
    private func beginRequest() -> UUID {
        requestID = UUID(); queueUpdateTask?.cancel(); queueUpdateTask = nil; return requestID
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard token == requestID else { throw CancellationError() } }
    private func register(_ tracks: [Track], token: UUID) async throws -> (tracks: [Track], ids: [TrackID]) {
        guard let compositeSource else { throw TrackSourceError.invalidResponse }
        var accepted: [Track] = []; var ids: [TrackID] = []
        for track in tracks {
            try check(token)
            let id: TrackID; let route: TrackSourceRoute
            if track.isStream {
                guard let raw = Self.yandexTrackID(from: track) else { continue }
                id = TrackID(raw: raw); route = .yandex
            } else {
                guard track.url.isFileURL else { continue }
                id = TrackID(raw: track.id.uuidString); route = .local
            }
            let meta = TrackMeta(id: id, title: track.title, artist: track.artist,
                                 albumID: track.album.isEmpty ? nil : track.album,
                                 durationSec: track.duration, artworkURL: track.coverURL.flatMap(URL.init(string:)))
            if route == .local { await localSource.register(LocalTrackRecord(metadata: meta, fileURL: track.url)) }
            else { await yandexClient.register(meta) }
            try check(token); await compositeSource.register(id, route: route); try check(token)
            accepted.append(track); ids.append(id)
        }
        return (accepted, ids)
    }
    private func apply(_ state: PlaybackCoordinatorSnapshot) {
        if let index = state.currentIndex, queue.indices.contains(index), state.queue.indices.contains(index),
           queueIDs[index] == state.queue[index] {
            let changed = currentTrack?.id != queue[index].id
            currentTrack = queue[index]
            if changed { updatePlaybackStreamInfo(for: currentTrack) }
            let remainingAhead = queue.count - 1 - index
            if remainingAhead <= 2 {
                refillQueueIfNeeded()
            }
        }
        switch state.phase {
        case .idle:
            currentTrack = nil; isPlaying = false; isLoading = false
            updatePlaybackStreamInfo(for: nil)
        case .loading: isPlaying = false; isLoading = true
        case .playing:
            // Prefetch belongs to the next track. It must never turn the current
            // playing track into a loading/paused state in UI or Now Playing.
            isPlaying = true; isLoading = false
            if currentCodec == nil { updatePlaybackStreamInfo(for: currentTrack) }
        case .paused, .ready: isPlaying = false; isLoading = false
        case .failed(let error): isPlaying = false; isLoading = false; lastError = error
        }
        if let error = state.lastQueueError { lastError = error }
    }

    private var isRefillingWave = false
    private var lastRefillDate: Date?

    private func waitForNextTrack() async {
        for _ in 0..<40 {
            guard let index = coordinator?.snapshot().currentIndex else { return }
            if index + 1 < queue.count { return }
            if !isRefillingWave { refillQueueIfNeeded() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func refillQueueIfNeeded() {
        guard !isRefillingWave, let current = currentTrack, let coordinator else { return }
        let now = Date()
        if let last = lastRefillDate, now.timeIntervalSince(last) < 4.0 { return }
        lastRefillDate = now

        let currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        let remainingAhead = queue.count - 1 - currentIndex
        guard remainingAhead <= 5 else { return }

        isRefillingWave = true
        Task { [weak self] in
            defer { self?.isRefillingWave = false }
            guard let self else { return }
            let ym = YandexMusicService.shared
            let rawTracks: [Track]
            if MoodRadioEngine.shared.isTrackWaveActive || ym.activeStationId?.hasPrefix("track:") == true {
                rawTracks = await MoodRadioEngine.shared.refillTrackWaveQueue(target: 30)
            } else {
                let stationId = ym.activeStationId ?? ym.waveMoodStation.stationId
                rawTracks = (await ym.buildWaveQueue(
                    stationId: stationId,
                    target: 30
                )).map { $0.toTrack() }
            }
            let ranked = UserTasteEngine.shared.filterAndRankWave(tracks: rawTracks)
            let existing = Set(self.queue.map(\.id))
            let fresh = ranked.filter {
                !existing.contains($0.id) && $0.id != current.id &&
                !UserTasteEngine.shared.isDisliked(track: $0)
            }
            guard !fresh.isEmpty else { return }

            do {
                let token = self.requestID
                let registered = try await self.register(fresh, token: token)
                try self.check(token)
                self.queue.append(contentsOf: registered.tracks)
                self.queueIDs.append(contentsOf: registered.ids)
                try await coordinator.appendQueue(registered.ids)
                try self.check(token)
                self.apply(coordinator.snapshot())
                SonivoDiagnostics.log("[AutoMix V2] Infinite queue refill: +\(fresh.count) tracks", tag: "WAVE")
            } catch {
                // Ignore cancellation during queue refill
            }
        }
    }
    private func updatePlaybackStreamInfo(for track: Track?) {
        guard let track else {
            currentCodec = nil
            currentBitrate = nil
            return
        }
        if let yandexId = Self.yandexTrackID(from: track) {
            let trackId = TrackID(raw: yandexId)
            Task { [weak self] in
                guard let self else { return }
                if let info = await self.yandexClient.streamInfo(for: trackId) {
                    await MainActor.run {
                        self.currentCodec = info.codec
                        self.currentBitrate = info.bitrate
                    }
                } else {
                    let ext = track.url.pathExtension.lowercased()
                    let c = (ext == "flac" || ext == "alac" || ext == "wav") ? "flac" : (ext == "mp3" ? "mp3" : (ext == "m4a" || ext == "aac" ? "aac" : nil))
                    let b = (c == "flac") ? 1411 : (c == "mp3" ? 320 : 256)
                    await MainActor.run {
                        self.currentCodec = c
                        self.currentBitrate = b
                    }
                }
            }
        } else {
            let ext = track.url.pathExtension.lowercased()
            let c = (ext == "flac" || ext == "alac" || ext == "wav") ? "flac" : (ext == "mp3" ? "mp3" : (ext == "m4a" || ext == "aac" ? "aac" : (ext.isEmpty ? nil : ext)))
            let b = (c == "flac") ? 1411 : (c == "mp3" ? 320 : 256)
            currentCodec = c
            currentBitrate = b
        }
    }
    private func fail(_ message: String, category: String) async {
        isLoading = false; isPlaying = false; lastError = message
        await diagnostics.record(MixDiagnosticEvent(level: .error, category: category, message: message))
    }
    private static func yandexTrackID(from track: Track) -> String? {
        if let parsed = YandexMusicService.ymId(fromFileName: track.fileName) { return parsed }
        guard let raw = track.streamUrlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, URL(string: raw)?.scheme == nil else { return nil }
        return raw
    }
    private static func userMessage(for error: Error) -> String {
        guard let sourceError = error as? TrackSourceError else { return String(describing: error) }
        switch sourceError {
        case .authenticationRequired: return "Нужно заново войти в Яндекс Музыку"
        case .trackUnavailable, .noDownloadOption: return "Трек сейчас недоступен для загрузки"
        case .httpStatus(let code): return "Ошибка загрузки Яндекс Музыки: HTTP \(code)"
        default: return String(describing: sourceError)
        }
    }
}

@MainActor
@Observable
final class PlaybackCommandRouter {
    static let shared = PlaybackCommandRouter(); private var installed = false; private init() {}
    private(set) var owner: PlaybackOwner = .legacy
    private(set) var isBusy = false
    private var requestID = 0
    private var transportTask: Task<Void, Never>?
    private var pendingTransportOperation: (@MainActor (PlaybackOwner) async -> Void)?
    private var seekTask: Task<Void, Never>?
    private var seekRequestID = 0

    func install() {
        guard !installed else { return }; installed = true
        owner = AutoMixEngineSelectionStore.shared.isNeuroEnabled ? .neuroMix :
            (AutoMixEngineSelectionStore.shared.isV2Enabled ? .autoMixV2 : .legacy)
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand]
        commands.forEach { $0.removeTarget(nil); $0.isEnabled = true }
        center.playCommand.addTarget { _ in Task { @MainActor in Self.shared.play() }; return .success }
        center.pauseCommand.addTarget { _ in Task { @MainActor in Self.shared.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in Self.shared.toggle() }; return .success }
        center.nextTrackCommand.addTarget { _ in Task { @MainActor in Self.shared.next() }; return .success }
        center.previousTrackCommand.addTarget { _ in Task { @MainActor in Self.shared.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in Self.shared.seek(to: event.positionTime) }; return .success
        }
    }

    func selectionChanged() {
        transportTask?.cancel()
        requestID += 1
        isBusy = false
        let target: PlaybackOwner = AutoMixEngineSelectionStore.shared.isNeuroEnabled ? .neuroMix :
            (AutoMixEngineSelectionStore.shared.isV2Enabled ? .autoMixV2 : .legacy)
        let legacyTrack = PlayerCore.shared.currentTrack
        let legacyQueue = PlayerCore.shared.queue
        owner = target
        if target != .legacy {
            PlayerCore.shared.stopAndClear()
        }
        Task { @MainActor in
            switch target {
            case .legacy:
                await AutoMixV2Runtime.shared.stop()
                await NeuroMixRuntime.shared.stop()
            case .autoMixV2:
                await NeuroMixRuntime.shared.stop()
                if let legacyTrack {
                    _ = await AutoMixV2Runtime.shared.play(legacyTrack, queue: legacyQueue)
                }
            case .neuroMix:
                await AutoMixV2Runtime.shared.stop()
                if let legacyTrack {
                    _ = await NeuroMixRuntime.shared.play(legacyTrack, queue: legacyQueue)
                }
            }
        }
    }

    private func owner(for track: Track) -> PlaybackOwner {
        if AutoMixEngineSelectionStore.shared.isNeuroEnabled { return .neuroMix }
        if AutoMixEngineSelectionStore.shared.isV2Enabled { return .autoMixV2 }
        return .legacy
    }

    private func stopOtherEngines(except target: PlaybackOwner) async {
        if target != .legacy { PlayerCore.shared.stopAndClear() }
        if target != .autoMixV2 { await AutoMixV2Runtime.shared.stop() }
        if target != .neuroMix { await NeuroMixRuntime.shared.stop() }
    }

    func play(_ track: Track, queue: [Track]) {
        let target = owner(for: track)
        if target == owner {
            let activeTrack: Track? = switch target {
            case .legacy: PlayerCore.shared.currentTrack
            case .autoMixV2: AutoMixV2Runtime.shared.currentTrack
            case .neuroMix: NeuroMixRuntime.shared.currentTrack
            }
            if activeTrack?.id == track.id {
                switch target {
                case .legacy where PlayerCore.shared.isPlaying: return
                case .autoMixV2 where AutoMixV2Runtime.shared.isPlaying || AutoMixV2Runtime.shared.isLoading: return
                case .neuroMix where NeuroMixRuntime.shared.isPlaying: return
                default: break
                }
            }
        }
        owner = target
        transportTask?.cancel()
        requestID += 1
        let request = requestID
        isBusy = true
        transportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await stopOtherEngines(except: target)
            guard request == requestID, !Task.isCancelled else { return }
            switch target {
            case .legacy:
                PlayerCore.shared.play(track, newQueue: queue)
            case .autoMixV2:
                _ = await AutoMixV2Runtime.shared.play(track, queue: queue)
            case .neuroMix:
                _ = await NeuroMixRuntime.shared.play(track, queue: queue)
            }
            if request == requestID {
                self.isBusy = false
                self.transportTask = nil
            }
        }
    }
    func play() {
        transportTask?.cancel()
        requestID += 1
        let request = requestID
        isBusy = true
        transportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch owner {
            case .legacy:
                PlayerCore.shared.resume()
            case .autoMixV2:
                _ = await AutoMixV2Runtime.shared.play()
            case .neuroMix:
                _ = await NeuroMixRuntime.shared.play()
            }
            if request == requestID {
                self.isBusy = false
                self.transportTask = nil
            }
        }
    }
    func pause() {
        transportTask?.cancel(); requestID += 1; isBusy = false
        switch owner {
        case .legacy: PlayerCore.shared.pause()
        case .autoMixV2: Task { await AutoMixV2Runtime.shared.pause() }
        case .neuroMix: Task { await NeuroMixRuntime.shared.pause() }
        }
    }
    func stopAndClear() {
        transportTask?.cancel(); requestID += 1; isBusy = false
        PlayerCore.shared.stopAndClear()
        let target = owner
        Task { @MainActor in
            switch target {
            case .legacy: break
            case .autoMixV2: await AutoMixV2Runtime.shared.stop()
            case .neuroMix: await NeuroMixRuntime.shared.stop()
            }
        }
    }
    func toggle() {
        transportTask?.cancel(); requestID += 1
        switch owner {
        case .legacy: PlayerCore.shared.togglePlay()
        case .autoMixV2: Task { await AutoMixV2Runtime.shared.toggle() }
        case .neuroMix:
            Task { if NeuroMixRuntime.shared.isPlaying { await NeuroMixRuntime.shared.pause() } else { _ = await NeuroMixRuntime.shared.play() } }
        }
    }
    func next() {
        enqueueTransport { owner in
            switch owner {
            case .legacy: PlayerCore.shared.next()
            case .autoMixV2: await AutoMixV2Runtime.shared.next()
            case .neuroMix: await NeuroMixRuntime.shared.next()
            }
        }
    }
    func previous() {
        enqueueTransport { owner in
            switch owner {
            case .legacy: PlayerCore.shared.previous()
            case .autoMixV2: await AutoMixV2Runtime.shared.previous()
            case .neuroMix: await NeuroMixRuntime.shared.previous()
            }
        }
    }
    func seek(to seconds: Double) {
        seekTask?.cancel()
        seekRequestID += 1
        let request = seekRequestID
        let target = owner
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard !Task.isCancelled, request == self.seekRequestID else { return }
            switch target {
            case .legacy: PlayerCore.shared.seek(to: seconds)
            case .autoMixV2: await AutoMixV2Runtime.shared.seek(to: seconds)
            case .neuroMix: await NeuroMixRuntime.shared.seek(to: seconds)
            }
            if request == self.seekRequestID { self.seekTask = nil }
        }
    }
    private func enqueueTransport(_ operation: @escaping @MainActor (PlaybackOwner) async -> Void) {
        if transportTask != nil {
            pendingTransportOperation = operation
            return
        }
        requestID += 1
        let request = requestID
        let target = owner
        transportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(target)
            if request == requestID {
                while let pending = self.pendingTransportOperation {
                    self.pendingTransportOperation = nil
                    await pending(target)
                }
                self.isBusy = false
                self.transportTask = nil
            }
        }
    }
}

extension AutoMixV2Runtime {
    var playbackQueue: [Track] { queue }
    var incomingTrack: Track? {
        guard let coordinator else { return nil }
        let s = coordinator.snapshot()
        if s.isTransitioning, let idx = s.preparedIndex, queue.indices.contains(idx) {
            return queue[idx]
        }
        return nil
    }
    func playbackTimeline() async -> (position: Double, duration: Double, isTransitioning: Bool, transitionProgress: Double)? {
        guard let coordinator else { return nil }
        let token = requestID; let before = coordinator.snapshot(); let engine = await coordinator.engineSnapshot(); let after = coordinator.snapshot()
        guard token == requestID, before.activeDeck == after.activeDeck,
              before.currentIndex == after.currentIndex, before.phase == after.phase else { return nil }
        let deck = after.activeDeck == .a ? engine.deckA : engine.deckB
        let duration = deck.durationSeconds ?? currentTrack?.duration ?? 0
        let progress = coordinator.transitionProgress ?? (after.isTransitioning ? 0.5 : 0.0)
        return (max(0, deck.positionSeconds), duration.isFinite ? max(0, duration) : 0, after.isTransitioning, progress)
    }
}
