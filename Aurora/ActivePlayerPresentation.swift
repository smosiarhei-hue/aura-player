// Path: Aurora/ActivePlayerPresentation.swift

import AudioEngineCore
import Foundation
import Observation

/// UI-owned adapter: never mirrors V2 state into the legacy audio engine.
@Observable
@MainActor
final class ActivePlayerPresentation {
    private let legacy: PlayerCore
    private let runtime: AutoMixV2Runtime
    private let selection: AutoMixEngineSelectionStore
    private let router: PlaybackCommandRouter
    private var timelineTrackID: UUID?
    private var timelinePosition: Double = 0
    private var timelineDuration: Double = 0
    private var timelineTransitioning = false

    init(legacy: PlayerCore = .shared, runtime: AutoMixV2Runtime = .shared,
         selection: AutoMixEngineSelectionStore = .shared, router: PlaybackCommandRouter = .shared) {
        self.legacy = legacy
        self.runtime = runtime
        self.selection = selection
        self.router = router
    }
    var isV2Enabled: Bool { selection.isV2Enabled }
    var currentTrack: Track? { isV2Enabled ? runtime.currentTrack : legacy.currentTrack }
    var displayTrack: Track? { isV2Enabled ? runtime.currentTrack : legacy.displayTrack }
    var isPlaying: Bool { isV2Enabled ? runtime.isPlaying : legacy.isPlaying }
    var isLoading: Bool { isV2Enabled && runtime.isLoading }
    var isTransitionActive: Bool { isV2Enabled ? timelineTransitioning : AutoMixDJEngine.shared.isTransitionActive }
    var progress: Double {
        guard isV2Enabled else { return legacy.progress }
        return timelineTrackID == currentTrack?.id ? timelinePosition : 0
    }
    var duration: Double {
        guard isV2Enabled else { return legacy.duration }
        let value = timelineTrackID == currentTrack?.id && timelineDuration > 0
            ? timelineDuration : (currentTrack?.duration ?? 0)
        return value.isFinite ? max(0, value) : 0
    }
    var queue: [Track] {
        get { isV2Enabled ? runtime.playbackQueue : legacy.queue }
        set {
            if isV2Enabled { runtime.replaceQueue(newValue) }
            else { legacy.queue = newValue }
        }
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
    func removeFromQueue(_ track: Track) {
        if isV2Enabled { queue = queue.filter { $0.id != track.id } }
        else { legacy.removeFromQueue(track) }
    }
    func stopAndClear() {
        if isV2Enabled { Task { await runtime.stop() } }
        else { legacy.stopAndClear() }
    }
    /// SwiftUI .task owns cancellation; there is no detached or global UI polling task.
    func observeTimeline() async {
        while !Task.isCancelled {
            if isV2Enabled {
                let trackID = currentTrack?.id
                if let timeline = await runtime.playbackTimeline(), !Task.isCancelled,
                   isV2Enabled, currentTrack?.id == trackID {
                    timelineTrackID = trackID
                    timelinePosition = timeline.position
                    timelineDuration = timeline.duration
                    timelineTransitioning = timeline.isTransitioning
                }
            }
            do { try await ContinuousClock().sleep(for: .milliseconds(200)) }
            catch { return }
        }
    }
}
