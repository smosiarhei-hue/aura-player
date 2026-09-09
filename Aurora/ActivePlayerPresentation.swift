// Path: Aurora/ActivePlayerPresentation.swift

import AudioEngineCore
import Foundation
import MixModels
import Observation
import TrackSource

@Observable
@MainActor
final class ActivePlayerPresentation {
    private let legacy: PlayerCore
    private let runtime: AutoMixV2Runtime
    private let selection: AutoMixEngineSelectionStore
    private let router: PlaybackCommandRouter
    private var timelineTrackID: UUID?
    private var timelinePosition = 0.0
    private var timelineDuration = 0.0
    private var timelineTransitioning = false
    private var networkFraction: Double?
    private var networkDownloading = false
    private var nextNetworkFraction: Double?
    private var nextNetworkDownloading = false

    init(legacy: PlayerCore = .shared, runtime: AutoMixV2Runtime = .shared,
         selection: AutoMixEngineSelectionStore = .shared, router: PlaybackCommandRouter = .shared) {
        self.legacy = legacy; self.runtime = runtime; self.selection = selection; self.router = router
    }
    var isV2Enabled: Bool { selection.isV2Enabled }
    var currentTrack: Track? { isV2Enabled ? runtime.currentTrack : legacy.currentTrack }
    var displayTrack: Track? { isV2Enabled ? runtime.currentTrack : legacy.displayTrack }
    var isPlaying: Bool { isV2Enabled ? runtime.isPlaying : legacy.isPlaying }
    var isLoading: Bool { isV2Enabled && runtime.isLoading }
    var isTransitionActive: Bool { isV2Enabled ? timelineTransitioning : AutoMixDJEngine.shared.isTransitionActive }
    var progress: Double { isV2Enabled ? (timelineTrackID == currentTrack?.id ? timelinePosition : 0) : legacy.progress }
    var duration: Double {
        guard isV2Enabled else { return legacy.duration }
        let value = timelineTrackID == currentTrack?.id && timelineDuration > 0 ? timelineDuration : (currentTrack?.duration ?? 0)
        return value.isFinite ? max(0, value) : 0
    }
    var downloadProgress: Double? { isV2Enabled ? networkFraction : nil }
    var isDownloading: Bool { isV2Enabled && networkDownloading }
    var nextDownloadProgress: Double? { isV2Enabled ? nextNetworkFraction : nil }
    var isNextDownloading: Bool { isV2Enabled && nextNetworkDownloading }
    var queue: [Track] {
        get { isV2Enabled ? runtime.playbackQueue : legacy.queue }
        set { if isV2Enabled { runtime.replaceQueue(newValue) } else { legacy.queue = newValue } }
    }
    var currentCodec: String? { isV2Enabled ? nil : legacy.currentCodec }
    var currentBitrate: Int? { isV2Enabled ? nil : legacy.currentBitrate }
    var audioQuality: AudioQuality { legacy.audioQuality }
    func selectQuality(_ quality: AudioQuality) { if !isV2Enabled { legacy.selectQuality(quality) } }
    func formatted(_ seconds: Double) -> String { legacy.formatted(seconds) }
    func togglePlay() { router.toggle() }
    func previous() { router.previous() }
    func next() { router.next() }
    func seek(to seconds: Double) { router.seek(to: seconds) }
    func play(_ track: Track) { router.play(track, queue: queue) }
    func removeFromQueue(_ track: Track) { if isV2Enabled { queue = queue.filter { $0.id != track.id } } else { legacy.removeFromQueue(track) } }
    func stopAndClear() { if isV2Enabled { Task { await runtime.stop() } } else { legacy.stopAndClear() } }

    func observeTimeline() async {
        while !Task.isCancelled {
            if isV2Enabled {
                let track = currentTrack; let trackID = track?.id
                if let timeline = await runtime.playbackTimeline(), !Task.isCancelled,
                   isV2Enabled, currentTrack?.id == trackID {
                    timelineTrackID = trackID; timelinePosition = timeline.position
                    timelineDuration = timeline.duration; timelineTransitioning = timeline.isTransitioning
                }
                let currentState = await downloadState(for: track)
                networkFraction = currentState?.fraction; networkDownloading = currentState?.isDownloading ?? false
                let list = runtime.playbackQueue
                let next = track.flatMap { current in
                    list.firstIndex(where: { $0.id == current.id }).flatMap { $0 + 1 < list.count ? list[$0 + 1] : nil }
                }
                let nextState = await downloadState(for: next)
                nextNetworkFraction = nextState?.fraction; nextNetworkDownloading = nextState?.isDownloading ?? false
            }
            do { try await ContinuousClock().sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    private func downloadState(for track: Track?) async -> TrackDownloadProgress? {
        guard let track, track.isStream,
              let raw = YandexMusicService.ymId(fromFileName: track.fileName) else { return nil }
        return await DownloadProgressStore.shared.snapshot(for: TrackID(raw: raw))
    }
}
