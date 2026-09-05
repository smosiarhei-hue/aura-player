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

    private init() {
        isV2Enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }
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
    private var currentIndex: Int?
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

        do {
            let cache = try TrackFileCache(directory: TrackFileCache.defaultDirectory())
            let yandex = YandexTrackSource(client: client, cache: cache, maximumParallelDownloads: 2)
            let composite = CompositeTrackSource(localSource: local, yandexSource: yandex)
            compositeSource = composite
            coordinator = PlaybackCoordinator(
                source: composite,
                engine: try DualDeckAudioEngine()
            )
        } catch {
            compositeSource = nil
            coordinator = nil
            lastError = String(describing: error)
        }
    }

    func engineSelectionChanged(isV2Enabled: Bool) async {
        if isV2Enabled {
            await adoptLegacyTrackIfNeeded()
        } else {
            await stop()
        }
    }

    func adoptLegacyTrackIfNeeded() async {
        guard currentTrack == nil, let track = PlayerCore.shared.currentTrack else { return }
        await play(track, queue: PlayerCore.shared.queue)
    }

    func play(_ track: Track, queue newQueue: [Track]) async {
        guard let coordinator, let compositeSource else {
            lastError = "AutoMix V2 audio engine недоступен"
            return
        }

        queue = newQueue.isEmpty ? [track] : newQueue
        currentIndex = queue.firstIndex(where: { $0.id == track.id })
        currentTrack = track
        isLoading = true
        isPlaying = false
        lastError = nil

        let id: TrackID
        let route: TrackSourceRoute
        if track.isStream {
            guard let yandexID = Self.yandexTrackID(from: track) else {
                lastError = "Не удалось определить ID трека Яндекс Музыки"
                isLoading = false
                await diagnostics.record(MixDiagnosticEvent(level: .error, category: "source", message: lastError ?? "Invalid Yandex track ID"))
                return
            }
            id = TrackID(raw: yandexID)
            route = .yandex
        } else {
            guard track.url.isFileURL else {
                lastError = "Локальный трек не содержит прямой файловый URL"
                isLoading = false
                return
            }
            id = TrackID(raw: track.id.uuidString)
            route = .local
        }

        let meta = TrackMeta(
            id: id,
            title: track.title,
            artist: track.artist,
            albumID: track.album.isEmpty ? nil : track.album,
            durationSec: track.duration,
            artworkURL: track.coverURL.flatMap(URL.init(string:))
        )

        if route == .local {
            await localSource.register(LocalTrackRecord(metadata: meta, fileURL: track.url))
        } else {
            await yandexClient.register(meta)
        }
        await compositeSource.register(id, route: route)

        // Legacy must be silent before the V2 download/prepare pipeline starts.
        PlayerCore.shared.stopAndClear()
        await diagnostics.record(MixDiagnosticEvent(category: "source", message: "Loading \(route.rawValue) track \(track.title)"))

        do {
            try await coordinator.play(trackID: id)
            isPlaying = true
            await diagnostics.record(MixDiagnosticEvent(category: "playback", message: "Started \(route.rawValue) track \(track.title)"))
        } catch {
            isPlaying = false
            lastError = Self.userMessage(for: error)
            await diagnostics.record(MixDiagnosticEvent(level: .error, category: "playback", message: lastError ?? "Unknown error"))
        }
        isLoading = false
    }

    func play() async {
        if currentTrack == nil {
            await adoptLegacyTrackIfNeeded()
            return
        }
        guard let coordinator else { return }
        do {
            try await coordinator.resume()
            isPlaying = true
        } catch {
            lastError = Self.userMessage(for: error)
        }
    }

    func pause() async {
        guard let coordinator else { return }
        await coordinator.pause()
        isPlaying = false
    }

    func stop() async {
        guard let coordinator else { return }
        await coordinator.stop()
        isPlaying = false
        isLoading = false
        currentTrack = nil
        currentIndex = nil
        queue = []
    }

    func toggle() async {
        isPlaying ? await pause() : await play()
    }

    func next() async {
        guard !queue.isEmpty else {
            await adoptLegacyTrackIfNeeded()
            return
        }
        let index = currentIndex ?? -1
        let nextIndex = index + 1 < queue.count ? index + 1 : 0
        await play(queue[nextIndex], queue: queue)
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        let index = currentIndex ?? 0
        let previousIndex = index > 0 ? index - 1 : max(0, queue.count - 1)
        await play(queue[previousIndex], queue: queue)
    }

    func seek(to seconds: Double) async {
        guard let coordinator else { return }
        do {
            try await coordinator.seek(to: seconds)
        } catch {
            lastError = Self.userMessage(for: error)
        }
    }

    func interruptionBegan() async {
        guard let coordinator else { return }
        await coordinator.handleInterruptionBegan()
        isPlaying = false
    }

    func interruptionEnded(shouldResume: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.handleInterruptionEnded(systemShouldResume: shouldResume)
            isPlaying = shouldResume
        } catch {
            lastError = Self.userMessage(for: error)
        }
    }

    func engineConfigurationChanged() async {
        guard let coordinator else { return }
        do {
            try await coordinator.handleEngineConfigurationChange()
        } catch {
            lastError = Self.userMessage(for: error)
        }
    }

    func refreshDiagnostics() async {
        guard let coordinator else {
            diagnosticReport = lastError ?? "AutoMix V2 audio engine недоступен"
            return
        }
        diagnosticReport = await diagnostics.textReport(coordinator: coordinator)
    }

    private static func yandexTrackID(from track: Track) -> String? {
        if let parsed = YandexMusicService.ymId(fromFileName: track.fileName) {
            return parsed
        }
        guard let raw = track.streamUrlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              URL(string: raw)?.scheme == nil else {
            return nil
        }
        return raw
    }

    private static func userMessage(for error: Error) -> String {
        guard let sourceError = error as? TrackSourceError else {
            return String(describing: error)
        }
        switch sourceError {
        case .authenticationRequired:
            return "Нужно заново войти в Яндекс Музыку"
        case .trackUnavailable, .noDownloadOption:
            return "Трек сейчас недоступен для загрузки"
        case .httpStatus(let code):
            return "Ошибка загрузки Яндекс Музыки: HTTP \(code)"
        default:
            return String(describing: sourceError)
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
        let commands: [MPRemoteCommand] = [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.changePlaybackPositionCommand
        ]
        commands.forEach { $0.removeTarget(nil) }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { _ in
            Task { @MainActor in PlaybackCommandRouter.shared.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in PlaybackCommandRouter.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in PlaybackCommandRouter.shared.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in PlaybackCommandRouter.shared.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in PlaybackCommandRouter.shared.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor in PlaybackCommandRouter.shared.seek(to: seconds) }
            return .success
        }
    }

    func play(_ track: Track, queue: [Track]) {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.play(track, queue: queue) }
        } else {
            PlayerCore.shared.play(track, newQueue: queue)
        }
    }

    func play() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.play() }
        } else {
            PlayerCore.shared.resume()
        }
    }

    func pause() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.pause() }
        } else {
            PlayerCore.shared.pause()
        }
    }

    func toggle() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.toggle() }
        } else {
            PlayerCore.shared.togglePlay()
        }
    }

    func next() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.next() }
        } else {
            PlayerCore.shared.next()
        }
    }

    func previous() {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.previous() }
        } else {
            PlayerCore.shared.previous()
        }
    }

    func seek(to seconds: Double) {
        if AutoMixEngineSelectionStore.shared.isV2Enabled {
            Task { await AutoMixV2Runtime.shared.seek(to: seconds) }
        } else {
            PlayerCore.shared.seek(to: seconds)
        }
    }
}
