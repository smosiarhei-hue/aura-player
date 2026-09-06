// Path: Aurora/AutoMixV2AppBridge.swift

@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import AudioEngineCore
import MixDiagnostics
import MixModels
import Observation
import PlaybackCoordinator
import TrackSource

@Observable
@MainActor
final class AutoMixEngineSelectionStore {
    static let shared = AutoMixEngineSelectionStore()
    static let defaultsKey = "automix.v2.enabled"
    var isV2Enabled: Bool {
        didSet {
            UserDefaults.standard.set(isV2Enabled, forKey: Self.defaultsKey)
            PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            Task { await AutoMixV2Runtime.shared.engineSelectionChanged(isV2Enabled: isV2Enabled) }
        }
    }
    private init() { isV2Enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey) }
}

@Observable
@MainActor
final class AutoMixV2Runtime {
    static let shared = AutoMixV2Runtime()
    private let localSource: LocalTrackSource
    private let yandexClient: AutoMixV2YandexDownloadClient
    private let compositeSource: CompositeTrackSource?
    private let coordinator: PlaybackCoordinator?
    let diagnostics = MixDiagnosticsStore()
    private var queue: [Track] = []
    private var queueIDs: [TrackID] = []
    private var requestID = UUID()
    private var queueUpdateTask: Task<Void, Never>?
    private(set) var currentTrack: Track?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var diagnosticReport = "Нажмите «Обновить отчёт»."

    private init() {
        let local = LocalTrackSource()
        let client = AutoMixV2YandexDownloadClient()
        localSource = local
        yandexClient = client
        let builtComposite: CompositeTrackSource?
        let builtCoordinator: PlaybackCoordinator?
        var startupError: String?
        do {
            let cache = try TrackFileCache(directory: TrackFileCache.defaultDirectory())
            let yandex = YandexTrackSource(client: client, cache: cache, maximumParallelDownloads: 2)
            let composite = CompositeTrackSource(localSource: local, yandexSource: yandex)
            let engine = try DualDeckAudioEngine()
            builtComposite = composite
            builtCoordinator = PlaybackCoordinator(source: composite, engine: engine)
        } catch {
            builtComposite = nil
            builtCoordinator = nil
            startupError = String(describing: error)
        }
        compositeSource = builtComposite
        coordinator = builtCoordinator
        lastError = startupError
        builtCoordinator?.onChange = { [weak self] state in self?.apply(state) }
    }
    func engineSelectionChanged(isV2Enabled: Bool) async {
        if isV2Enabled { await adoptLegacyTrackIfNeeded() }
        else { await stop() }
    }
    func adoptLegacyTrackIfNeeded() async {
        guard currentTrack == nil, let track = PlayerCore.shared.currentTrack else { return }
        await play(track, queue: PlayerCore.shared.queue)
    }
    func replaceQueue(_ newQueue: [Track]) {
        let token = beginRequest()
        queueUpdateTask = Task { [weak self] in
            guard let self, let coordinator else { return }
            do {
                let registered = try await register(newQueue, token: token)
                try check(token)
                queue = registered.tracks
                queueIDs = registered.ids
                try await coordinator.replaceQueue(registered.ids)
                try check(token)
                apply(coordinator.snapshot())
            } catch is CancellationError { return }
            catch {
                guard token == requestID else { return }
                lastError = Self.userMessage(for: error)
            }
        }
    }
    func play(_ track: Track, queue newQueue: [Track]) async {
        guard let coordinator else {
            lastError = "AutoMix V2 audio engine недоступен"
            return
        }
        let token = beginRequest()
        isLoading = true
        lastError = nil
        var tracks = newQueue.isEmpty ? [track] : newQueue
        if !tracks.contains(where: { $0.id == track.id }) { tracks.insert(track, at: 0) }
        do {
            let registered = try await register(tracks, token: token)
            try check(token)
            guard let index = registered.tracks.firstIndex(where: { $0.id == track.id }) else {
                throw TrackSourceError.invalidTrackID
            }
            queue = registered.tracks
            queueIDs = registered.ids
            PlayerCore.shared.stopAndClear()
            try await coordinator.play(queue: registered.ids, startIndex: index)
            try check(token)
            apply(coordinator.snapshot())
            await diagnostics.record(MixDiagnosticEvent(category: "playback", message: "Queue playback started"))
        } catch is CancellationError { return }
        catch {
            guard token == requestID else { return }
            await fail(Self.userMessage(for: error), category: "playback")
        }
    }
    func play() async {
        if currentTrack == nil { await adoptLegacyTrackIfNeeded(); return }
        guard let coordinator else { return }
        do { try await coordinator.resume() }
        catch is CancellationError { return }
        catch { lastError = Self.userMessage(for: error) }
    }
    func pause() async { await coordinator?.pause() }
    func stop() async {
        let token = beginRequest()
        await coordinator?.stop()
        guard token == requestID else { return }
        isPlaying = false
        isLoading = false
        currentTrack = nil
        queue = []
        queueIDs = []
    }
    func toggle() async { isPlaying ? await pause() : await play() }
    func next() async {
        guard let coordinator else { return }
        let token = beginRequest()
        do { try await coordinator.next() }
        catch is CancellationError { return }
        catch { if token == requestID { lastError = Self.userMessage(for: error) } }
    }
    func previous() async {
        guard let coordinator else { return }
        let token = beginRequest()
        do { try await coordinator.previous() }
        catch is CancellationError { return }
        catch { if token == requestID { lastError = Self.userMessage(for: error) } }
    }
    func seek(to seconds: Double) async {
        guard let coordinator else { return }
        let token = beginRequest()
        do { try await coordinator.seek(to: seconds) }
        catch is CancellationError { return }
        catch { if token == requestID { lastError = Self.userMessage(for: error) } }
    }
    func interruptionBegan() async { await coordinator?.handleInterruptionBegan() }
    func interruptionEnded(shouldResume: Bool) async {
        guard let coordinator else { return }
        do { try await coordinator.handleInterruptionEnded(systemShouldResume: shouldResume) }
        catch is CancellationError { return }
        catch { lastError = Self.userMessage(for: error) }
    }
    func engineConfigurationChanged() async {
        guard let coordinator else { return }
        do { try await coordinator.handleEngineConfigurationChange() }
        catch is CancellationError { return }
        catch { lastError = Self.userMessage(for: error) }
    }
    func refreshDiagnostics() async {
        guard let coordinator else {
            diagnosticReport = lastError ?? "AutoMix V2 audio engine недоступен"
            return
        }
        diagnosticReport = await diagnostics.textReport(coordinator: coordinator)
    }
    private func beginRequest() -> UUID {
        requestID = UUID()
        queueUpdateTask?.cancel()
        queueUpdateTask = nil
        return requestID
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == requestID else { throw CancellationError() }
    }
    /// Register every queue entry before handing ownership to the coordinator.
    /// Invalid entries are excluded; valid-but-unavailable downloads are handled by the coordinator.
    private func register(_ tracks: [Track], token: UUID) async throws -> (tracks: [Track], ids: [TrackID]) {
        guard let compositeSource else { throw TrackSourceError.invalidResponse }
        var accepted: [Track] = []
        var ids: [TrackID] = []
        for track in tracks {
            try check(token)
            let id: TrackID
            let route: TrackSourceRoute
            if track.isStream {
                guard let raw = Self.yandexTrackID(from: track) else { continue }
                id = TrackID(raw: raw)
                route = .yandex
            } else {
                guard track.url.isFileURL else { continue }
                id = TrackID(raw: track.id.uuidString)
                route = .local
            }
            let meta = TrackMeta(id: id, title: track.title, artist: track.artist,
                                 albumID: track.album.isEmpty ? nil : track.album,
                                 durationSec: track.duration, artworkURL: track.coverURL.flatMap(URL.init(string:)))
            if route == .local {
                await localSource.register(LocalTrackRecord(metadata: meta, fileURL: track.url))
            } else { await yandexClient.register(meta) }
            try check(token)
            await compositeSource.register(id, route: route)
            try check(token)
            accepted.append(track)
            ids.append(id)
        }
        return (accepted, ids)
    }
    private func apply(_ state: PlaybackCoordinatorSnapshot) {
        // Prefer occurrence index to preserve repeated tracks in a queue.
        if let index = state.currentIndex, queue.indices.contains(index),
           state.queue.indices.contains(index), queueIDs[index] == state.queue[index] {
            currentTrack = queue[index]
        }
        switch state.phase {
        case .idle:
            currentTrack = nil
            isPlaying = false
            isLoading = false
        case .loading:
            isPlaying = false
            isLoading = true
        case .playing:
            isPlaying = !state.waitingForNext
            isLoading = state.waitingForNext
        case .paused, .ready:
            isPlaying = false
            isLoading = false
        case .failed(let error):
            isPlaying = false
            isLoading = false
            lastError = error
        }
        if let error = state.lastQueueError { lastError = error }
    }
    private func fail(_ message: String, category: String) async {
        isLoading = false
        isPlaying = false
        lastError = message
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
final class PlaybackCommandRouter {
    static let shared = PlaybackCommandRouter()
    private var installed = false
    private init() {}
    func install() {
        guard !installed else { return }
        installed = true
        let center = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [center.playCommand, center.pauseCommand,
            center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand,
            center.changePlaybackPositionCommand]
        commands.forEach { $0.removeTarget(nil); $0.isEnabled = true }
        center.playCommand.addTarget { _ in Task { @MainActor in Self.shared.play() }; return .success }
        center.pauseCommand.addTarget { _ in Task { @MainActor in Self.shared.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in Self.shared.toggle() }; return .success }
        center.nextTrackCommand.addTarget { _ in Task { @MainActor in Self.shared.next() }; return .success }
        center.previousTrackCommand.addTarget { _ in Task { @MainActor in Self.shared.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in Self.shared.seek(to: event.positionTime) }
            return .success
        }
    }
    func play(_ track: Track, queue: [Track]) {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.play(track, queue: queue) } }
        else { PlayerCore.shared.play(track, newQueue: queue) }
    }
    func play() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.play() } }
        else { PlayerCore.shared.resume() }
    }
    func pause() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.pause() } }
        else { PlayerCore.shared.pause() }
    }
    func toggle() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.toggle() } }
        else { PlayerCore.shared.togglePlay() }
    }
    func next() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.next() } }
        else { PlayerCore.shared.next() }
    }
    func previous() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.previous() } }
        else { PlayerCore.shared.previous() }
    }
    func seek(to seconds: Double) {
        if AutoMixEngineSelectionStore.shared.isV2Enabled { Task { await AutoMixV2Runtime.shared.seek(to: seconds) } }
        else { PlayerCore.shared.seek(to: seconds) }
    }
}

// Read-only presentation access; the coordinator remains the owner of playback.
extension AutoMixV2Runtime {
    var playbackQueue: [Track] { queue }
    func playbackTimeline() async -> (position: Double, duration: Double, isTransitioning: Bool)? {
        guard let coordinator else { return nil }
        let token = requestID
        let before = coordinator.snapshot()
        let engine = await coordinator.engineSnapshot()
        let after = coordinator.snapshot()
        guard token == requestID, before.activeDeck == after.activeDeck,
              before.currentIndex == after.currentIndex, before.phase == after.phase else { return nil }
        let deck = after.activeDeck == .a ? engine.deckA : engine.deckB
        let duration = deck.durationSeconds ?? currentTrack?.duration ?? 0
        return (max(0, deck.positionSeconds), duration.isFinite ? max(0, duration) : 0, after.isTransitioning)
    }
}
