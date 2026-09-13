// Path: Aurora/ActivePlayerPresentation.swift

import AudioEngineCore
import Foundation
import MixModels
import Observation
import TrackSource

/// Presents whichever engine actually owns the audible track. This prevents a
/// legacy/local track from playing behind an empty V2 player UI.
@Observable
@MainActor
final class ActivePlayerPresentation {
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
         selection: AutoMixEngineSelectionStore = .shared, router: PlaybackCommandRouter = .shared) {
        self.legacy = legacy; self.runtime = runtime; self.neuroRuntime = .shared
        self.selection = selection; self.router = router
    }
    private var v2OwnsPlayback: Bool { selection.isV2Enabled && runtime.currentTrack != nil }
    private var neuroOwnsPlayback: Bool { selection.isNeuroEnabled && neuroRuntime.currentTrack != nil }
    var isV2Enabled: Bool { v2OwnsPlayback || neuroOwnsPlayback }
    var currentTrack: Track? {
        neuroOwnsPlayback ? neuroRuntime.currentTrack : (v2OwnsPlayback ? runtime.currentTrack : legacy.currentTrack)
    }
    var incomingTrack: Track? { v2OwnsPlayback ? runtime.incomingTrack : legacy.incomingTrack }
    var transitionProgress: Double { v2OwnsPlayback ? timelineTransitionProgress : AutoMixDJEngine.shared.transitionProgress }
    var displayTrack: Track? {
        if isTransitionActive, let incoming = incomingTrack {
            return incoming
        }
        return neuroOwnsPlayback ? neuroRuntime.currentTrack : (v2OwnsPlayback ? runtime.currentTrack : legacy.displayTrack)
    }
    var isPlaying: Bool {
        neuroOwnsPlayback ? neuroRuntime.isPlaying :
            (v2OwnsPlayback ? (runtime.isPlaying || (runtime.isLoading && timelineAdvancing)) : legacy.isPlaying)
    }
    var isLoading: Bool { v2OwnsPlayback && runtime.isLoading && timelineDuration <= 0 && !timelineAdvancing }
    var isTransitionActive: Bool { v2OwnsPlayback ? timelineTransitioning : AutoMixDJEngine.shared.isTransitionActive }
    var progress: Double {
        neuroOwnsPlayback ? timelinePosition :
            (v2OwnsPlayback ? (timelineTrackID == runtime.currentTrack?.id ? timelinePosition : 0) : legacy.progress)
    }
    var duration: Double {
        guard v2OwnsPlayback else { return legacy.duration }
        let value = neuroOwnsPlayback ? (neuroRuntime.currentTrack?.duration ?? 0) :
            (timelineDuration > 0 ? timelineDuration : (runtime.currentTrack?.duration ?? 0))
        return value.isFinite ? max(0, value) : 0
    }
    var downloadProgress: Double? {
        if neuroOwnsPlayback {
            return 1.0
        } else if v2OwnsPlayback {
            return networkFraction
        } else if legacy.currentTrack?.isStream == true {
            return legacy.streamBufferFraction > 0 ? legacy.streamBufferFraction : nil
        } else {
            return 1.0 // Local file is 100% loaded
        }
    }
    var isDownloading: Bool { v2OwnsPlayback ? networkDownloading : (legacy.streamBufferFraction < 0.99 && legacy.currentTrack?.isStream == true) }
    var nextDownloadProgress: Double? { v2OwnsPlayback ? nextNetworkFraction : nil }
    var isNextDownloading: Bool { v2OwnsPlayback && nextNetworkDownloading }
    var queue: [Track] {
        get {
            neuroOwnsPlayback ? neuroRuntime.playbackQueue : (v2OwnsPlayback ? runtime.playbackQueue : legacy.queue)
        }
        set {
            if v2OwnsPlayback { runtime.replaceQueue(newValue) }
            else if !neuroOwnsPlayback { legacy.queue = newValue }
        }
    }
    var currentCodec: String? { v2OwnsPlayback ? runtime.currentCodec : legacy.currentCodec }
    var currentBitrate: Int? { v2OwnsPlayback ? runtime.currentBitrate : legacy.currentBitrate }
    var audioQuality: AudioQuality { legacy.audioQuality }
    func selectQuality(_ quality: AudioQuality) { legacy.selectQuality(quality) }
    func formatted(_ seconds: Double) -> String { legacy.formatted(seconds) }

    var sleepTimerMinutes: Int? { legacy.sleepTimerMinutes }
    var sleepTimerRemaining: Double? { legacy.sleepTimerRemaining }
    func setSleepTimer(minutes: Int?) { legacy.setSleepTimer(minutes: minutes) }

    var eqEnabled: Bool {
        get { legacy.eqEnabled }
        set { legacy.eqEnabled = newValue }
    }
    var eqGains: [Float] {
        get { legacy.eqGains }
        set { legacy.eqGains = newValue }
    }

    func togglePlay() {
        if neuroOwnsPlayback {
            Task { if neuroRuntime.isPlaying { await neuroRuntime.pause() } else { _ = await neuroRuntime.play() } }
        } else if v2OwnsPlayback { Task { await runtime.toggle() } } else { legacy.togglePlay() }
    }
    func pause() {
        if neuroOwnsPlayback { Task { await neuroRuntime.pause() } }
        else if v2OwnsPlayback { Task { await runtime.pause() } } else { legacy.pause() }
    }
    func resume() {
        if neuroOwnsPlayback { Task { _ = await neuroRuntime.play() } }
        else if v2OwnsPlayback { Task { await runtime.play() } } else { legacy.resume() }
    }
    func previous() {
        if neuroOwnsPlayback { Task { await neuroRuntime.previous() } }
        else if v2OwnsPlayback { Task { await runtime.previous() } } else { legacy.previous() }
    }
    func next() {
        if neuroOwnsPlayback { Task { await neuroRuntime.next() } }
        else if v2OwnsPlayback { Task { await runtime.next() } } else { legacy.next() }
    }
    func seek(to seconds: Double) {
        if neuroOwnsPlayback { Task { await neuroRuntime.seek(to: seconds) } }
        else if v2OwnsPlayback { Task { await runtime.seek(to: seconds) } } else { legacy.seek(to: seconds) }
    }
    func play(_ track: Track) { router.play(track, queue: queue) }
    func removeFromQueue(_ track: Track) {
        if v2OwnsPlayback { runtime.replaceQueue(runtime.playbackQueue.filter { $0.id != track.id }) }
        else { legacy.removeFromQueue(track) }
    }
    func stopAndClear() {
        if neuroOwnsPlayback { Task { await neuroRuntime.stop() } }
        else if v2OwnsPlayback { Task { await runtime.stop() } } else { legacy.stopAndClear() }
    }

    func observeTimeline() async {
        while !Task.isCancelled {
            if neuroOwnsPlayback {
                let track = neuroRuntime.currentTrack
                let trackID = track?.id
                if let timeline = await neuroRuntime.playbackTimeline(), !Task.isCancelled,
                   neuroOwnsPlayback, neuroRuntime.currentTrack?.id == trackID {
                    timelineTrackID = trackID
                    previousTimelinePosition = timelinePosition
                    timelinePosition = timeline.position
                    timelineAdvancing = timeline.position > previousTimelinePosition + 0.005
                    timelineDuration = timeline.duration
                    timelineTransitioning = timeline.isTransitioning
                    timelineTransitionProgress = timeline.transitionProgress
                }
                networkFraction = nil
                networkDownloading = false
                nextNetworkFraction = nil
                nextNetworkDownloading = false
            } else if v2OwnsPlayback {
                let track = runtime.currentTrack; let trackID = track?.id
                if let timeline = await runtime.playbackTimeline(), !Task.isCancelled,
                   v2OwnsPlayback, runtime.currentTrack?.id == trackID {
                    timelineTrackID = trackID
                    previousTimelinePosition = timelinePosition
                    timelinePosition = timeline.position
                    timelineAdvancing = timeline.position > previousTimelinePosition + 0.005
                    timelineDuration = timeline.duration
                    timelineTransitioning = timeline.isTransitioning
                    timelineTransitionProgress = timeline.transitionProgress
                }
                let currentState = await downloadState(for: track)
                networkFraction = currentState?.fraction; networkDownloading = currentState?.isDownloading ?? false
                let list = runtime.playbackQueue
                let next = track.flatMap { current in
                    list.firstIndex(where: { $0.id == current.id }).flatMap { $0 + 1 < list.count ? list[$0 + 1] : nil }
                }
                let nextState = await downloadState(for: next)
                nextNetworkFraction = nextState?.fraction; nextNetworkDownloading = nextState?.isDownloading ?? false
            } else {
                timelineTrackID = nil; timelinePosition = 0; timelineDuration = 0
                previousTimelinePosition = 0; timelineAdvancing = false; timelineTransitioning = false
                timelineTransitionProgress = 0.0
                networkFraction = nil; networkDownloading = false; nextNetworkFraction = nil; nextNetworkDownloading = false
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
