// Path: Sonivo/ActivePlayerPresentation.swift

import AudioEngineCore
import Foundation
import MixModels
import Observation
import TrackSource

@Observable
@MainActor
final class ActivePlayerPresentation {
    static let shared = ActivePlayerPresentation()

    private let legacy: PlayerCore
    private let runtime: AutoMixV2Runtime
    private let neuroRuntime: NeuroMixRuntime
    private let selection: AutoMixEngineSelectionStore
    private let router: PlaybackCommandRouter
    private var timelineTrackID: UUID?
    private var timelinePosition = 0.0
    private var timelineDuration = 0.0
    private var previousTimelinePosition = 0.0
    private var timelineAdvancing = false
    private var timelineTransitioning = false
    private var timelineTransitionProgress = 0.0
    private var networkFraction: Double?
    private var networkDownloading = false
    private var nextNetworkFraction: Double?
    private var nextNetworkDownloading = false

    init(legacy: PlayerCore = .shared, runtime: AutoMixV2Runtime = .shared,
         selection: AutoMixEngineSelectionStore = .shared,
         router: PlaybackCommandRouter = .shared) {
        self.legacy = legacy
        self.runtime = runtime
        self.neuroRuntime = .shared
        self.selection = selection
        self.router = router
    }

    private var v2OwnsPlayback: Bool { false }
    private var neuroOwnsPlayback: Bool { false }
    var isV2Enabled: Bool { false }
    var currentTrack: Track? {
        legacy.currentTrack
    }
    var incomingTrack: Track? {
        legacy.incomingTrack
    }
    var transitionProgress: Double {
        AutoMixDJEngine.shared.transitionProgress
    }

    // Artwork, title, seek and transport controls must always address the deck
    // that is currently audible. In iOS 27 AutoMix, this switches on the Drop (T=0) hard cut.
    var displayTrack: Track? { legacy.displayTrack }

    var isPlaying: Bool {
        legacy.isPlaying
    }
    var isLoading: Bool {
        router.isBusy
    }
    var isTransitionActive: Bool {
        AutoMixDJEngine.shared.isTransitionActive
    }
    var progress: Double {
        legacy.progress
    }
    var duration: Double {
        legacy.duration
    }
    var downloadProgress: Double? {
        if legacy.currentTrack?.isStream == true {
            return legacy.streamBufferFraction > 0 ? legacy.streamBufferFraction : nil
        }
        return 1
    }
    var isDownloading: Bool {
        legacy.streamBufferFraction < 0.99 && legacy.currentTrack?.isStream == true
    }
    var nextDownloadProgress: Double? { nil }
    var isNextDownloading: Bool { false }
    var queue: [Track] {
        get {
            legacy.queue
        }
        set {
            legacy.queue = newValue
        }
    }

    /// Заменяет предстоящие треки в очереди активного движка без прерывания текущего звучания
    func replaceUpcomingQueue(with tracks: [Track]) {
        let current = currentTrack
        var newQ: [Track] = []
        if let current {
            newQ.append(current)
            var seen = Set([current.id])
            for t in tracks where seen.insert(t.id).inserted {
                newQ.append(t)
            }
        } else {
            newQ = tracks
        }
        self.queue = newQ
    }
    var currentCodec: String? { v2OwnsPlayback ? runtime.currentCodec : legacy.currentCodec }
    var currentBitrate: Int? { v2OwnsPlayback ? runtime.currentBitrate : legacy.currentBitrate }
    var audioQuality: AudioQuality { legacy.audioQuality }
    func selectQuality(_ quality: AudioQuality) { legacy.selectQuality(quality) }
    func formatted(_ seconds: Double) -> String { legacy.formatted(seconds) }

    var sleepTimerMinutes: Int? { legacy.sleepTimerMinutes }
    var sleepTimerRemaining: Double? { legacy.sleepTimerRemaining }
    var sleepTimerFormatted: String? { legacy.sleepTimerFormatted }
    func setSleepTimer(minutes: Int?) { legacy.setSleepTimer(minutes: minutes) }
    func extendSleepTimer(byMinutes: Int) { legacy.extendSleepTimer(byMinutes: byMinutes) }
    func cancelSleepTimer() { legacy.cancelSleepTimer() }

    var shuffle: Bool {
        get { legacy.shuffle }
        set { legacy.shuffle = newValue }
    }
    var repeatMode: RepeatMode {
        get { legacy.repeatMode }
        set { legacy.repeatMode = newValue }
    }

    var eqEnabled: Bool {
        get { legacy.eqEnabled }
        set { legacy.eqEnabled = newValue }
    }
    var eqGains: [Float] {
        get { legacy.eqGains }
        set { legacy.eqGains = newValue }
    }

    func togglePlay() { router.toggle() }
    func pause() { router.pause() }
    func resume() { router.play() }
    func previous() { router.previous() }
    func next() {
        if let current = currentTrack, current.isStream {
            let ymId = PlayerCore.yandexTrackID(from: current)
            if !ymId.isEmpty {
                YandexMusicService.shared.reportSkip(trackId: ymId)
            }
        }
        router.next()
    }
    func seek(to seconds: Double) { router.seek(to: seconds) }
    func play(_ track: Track) { router.play(track, queue: queue) }
    func removeFromQueue(_ track: Track) {
        legacy.removeFromQueue(track)
    }
    func stopAndClear() { router.stopAndClear() }

    func observeTimeline() async {
        while !Task.isCancelled {
            if neuroOwnsPlayback {
                let track = neuroRuntime.currentTrack
                let trackID = track?.id
                if timelineTrackID != trackID { resetTimeline(for: trackID) }
                if let timeline = await neuroRuntime.playbackTimeline(),
                   !Task.isCancelled, neuroOwnsPlayback,
                   neuroRuntime.currentTrack?.id == trackID {
                    applyTimeline(position: timeline.position, duration: timeline.duration,
                                  transitioning: timeline.isTransitioning,
                                  transitionProgress: timeline.transitionProgress)
                }
                clearNetworkProgress()
            } else if v2OwnsPlayback {
                let track = runtime.currentTrack
                let trackID = track?.id
                if timelineTrackID != trackID { resetTimeline(for: trackID) }
                if let timeline = await runtime.playbackTimeline(),
                   !Task.isCancelled, v2OwnsPlayback,
                   runtime.currentTrack?.id == trackID {
                    applyTimeline(position: timeline.position, duration: timeline.duration,
                                  transitioning: timeline.isTransitioning,
                                  transitionProgress: timeline.transitionProgress)
                }
                let currentState = await downloadState(for: track)
                networkFraction = currentState?.fraction
                networkDownloading = currentState?.isDownloading ?? false
                let list = runtime.playbackQueue
                let next = track.flatMap { current in
                    list.firstIndex(where: { $0.id == current.id }).flatMap {
                        $0 + 1 < list.count ? list[$0 + 1] : nil
                    }
                }
                let nextState = await downloadState(for: next)
                nextNetworkFraction = nextState?.fraction
                nextNetworkDownloading = nextState?.isDownloading ?? false
            } else {
                resetTimeline(for: nil)
                clearNetworkProgress()
            }
            let sleepMs = isPlaying ? 25 : 200
            do { try await ContinuousClock().sleep(for: .milliseconds(sleepMs)) }
            catch { return }
        }
    }

    private func resetTimeline(for trackID: UUID?) {
        timelineTrackID = trackID
        timelinePosition = 0
        timelineDuration = 0
        previousTimelinePosition = 0
        timelineAdvancing = false
        timelineTransitioning = false
        timelineTransitionProgress = 0
    }

    private func applyTimeline(position: Double, duration: Double,
                               transitioning: Bool, transitionProgress: Double) {
        previousTimelinePosition = timelinePosition
        timelinePosition = max(0, position)
        timelineAdvancing = timelinePosition > previousTimelinePosition + 0.005
        timelineDuration = duration.isFinite ? max(0, duration) : 0
        timelineTransitioning = transitioning
        timelineTransitionProgress = min(1, max(0, transitionProgress))
    }

    private func clearNetworkProgress() {
        networkFraction = nil
        networkDownloading = false
        nextNetworkFraction = nil
        nextNetworkDownloading = false
    }

    private func downloadState(for track: Track?) async -> TrackDownloadProgress? {
        guard let track, track.isStream,
              let raw = YandexMusicService.ymId(fromFileName: track.fileName) else { return nil }
        return await DownloadProgressStore.shared.snapshot(for: TrackID(raw: raw))
    }
}
