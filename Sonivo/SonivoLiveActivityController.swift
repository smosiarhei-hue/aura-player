import ActivityKit
import Foundation
import UIKit

/// ActivityKit is presentation-only. Never owns, starts or captures the audio stream.
@MainActor
final class SonivoLiveActivityController {
    static let shared = SonivoLiveActivityController()
    static let enabledKey = "appearance.liveActivityEnabled"
    static var isEmbedded: Bool { Bundle.main.object(forInfoDictionaryKey: "SonivoLiveActivityEmbedded") as? Bool == true }
    private var currentID: String?
    private var desired: SonivoActivityAttributes.ContentState?
    private var previous: SonivoActivityAttributes.ContentState?
    private var revision = 0
    private var worker: Task<Void, Never>?

    func refresh() {
        let core = PlayerCore.shared
        synchronize(track: core.currentTrack, playing: core.isPlaying, elapsed: core.progress, duration: core.duration)
    }

    func endForPlaybackHandoff() {
        guard currentID != nil || !Activity<SonivoActivityAttributes>.activities.isEmpty else { return }
        enqueue(nil)
    }

    func synchronize(track: Track?, playing: Bool, elapsed: Double, duration: Double) {
        guard PlaybackAudioSessionCoordinator.shared.allowsSystemPlaybackPublication() else {
            endForPlaybackHandoff()
            return
        }
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard Self.isEmbedded, enabled, ActivityAuthorizationInfo().areActivitiesEnabled, let track else {
            guard currentID != nil || !Activity<SonivoActivityAttributes>.activities.isEmpty else { return }
            enqueue(nil); return
        }
        let seconds = elapsed.isFinite ? max(0, elapsed) : 0
        let length = duration.isFinite ? min(86_400, max(0, duration)) : 0
        let position = min(seconds, length > 0 ? length : 86_400)
        let now = Date()
        let icon = AppIconManager.shared.selected ?? .music
        let key: String
        switch icon {
        case .signature: key = "signature"
        case .wordmark: key = "wordmark"
        case .classic: key = "classic"
        default: key = "music"
        }
        let state = SonivoActivityAttributes.ContentState(playbackID: track.id.uuidString,
            source: YandexMusicService.shared.activeStationId != nil ? "Моя волна" : "Музыка",
            icon: key, accentHex: ThemeFontManager.shared.selectedTheme.accentHex,
            isPlaying: playing, elapsed: position, duration: length,
            timelineStart: now.addingTimeInterval(-position), timelineEnd: now.addingTimeInterval(max(0, length - position)))
        // System timer renders the progress. Never send per-frame ActivityKit updates.
        if let old = previous, old.playbackID == state.playbackID, old.source == state.source,
           old.icon == state.icon, old.accentHex == state.accentHex, old.isPlaying == state.isPlaying,
           abs(old.duration - state.duration) < 1,
           (playing ? abs(old.timelineEnd.timeIntervalSince(state.timelineEnd)) < 2 : abs(old.elapsed - state.elapsed) < 0.1) {
            return
        }
        enqueue(state)
    }

    private func enqueue(_ state: SonivoActivityAttributes.ContentState?) {
        desired = state; previous = state; revision += 1
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while true {
                let version = self.revision, state = self.desired
                let foreground = UIApplication.shared.applicationState == .active
                self.currentID = await SonivoActivityRuntime.apply(currentID: self.currentID, state: state,
                                                                   canRequest: foreground)
                if state != nil, self.currentID == nil {
                    self.previous = nil // Retry on a later foreground/state event, never a tight loop.
                }
                if version == self.revision { break }
            }
        }
    }
}

/// SDK Activity handles are non-Sendable. Resolve and use them wholly on the generic
/// executor; only immutable state and IDs cross the UI actor boundary. One UI worker
/// serializes all calls here. No preconcurrency imports or unchecked Sendable wrappers.
nonisolated enum SonivoActivityRuntime {
    @concurrent static func apply(currentID: String?, state: SonivoActivityAttributes.ContentState?,
                                 canRequest: Bool) async -> String? {
        let activities = Activity<SonivoActivityAttributes>.activities
        let current = activities.first { $0.id == currentID } ?? activities.first
        for extra in activities where extra.id != current?.id {
            await extra.end(nil, dismissalPolicy: .immediate)
        }
        guard let state else {
            if let current { await current.end(nil, dismissalPolicy: .immediate) }
            return nil
        }
        if let current, current.activityState == .dismissed, current.content.state.playbackID == state.playbackID {
            return current.id // Respect user dismissal until the next track.
        }
        let content = ActivityContent(state: state, staleDate: state.isPlaying ? state.timelineEnd : nil)
        if let current, current.activityState == .active || current.activityState == .stale {
            await current.update(content)
            return current.id
        }
        guard state.isPlaying, canRequest else { return nil }
        do {
            return try Activity.request(attributes: SonivoActivityAttributes(brand: "Sonivo"),
                                        content: content, pushType: nil).id
        } catch { return nil }
    }
}
