import ActivityKit
import Foundation
import UIKit

/// ActivityKit is presentation-only. Never owns, starts or captures the audio stream.
@MainActor
final class SonivoLiveActivityController {
    static let shared = SonivoLiveActivityController()
    static let enabledKey = "appearance.liveActivityEnabled"
    static var isEmbedded: Bool { Bundle.main.object(forInfoDictionaryKey: "SonivoLiveActivityEmbedded") as? Bool == true }
    private var current: Activity<SonivoActivityAttributes>?
    private var desired: SonivoActivityAttributes.ContentState?
    private var previous: SonivoActivityAttributes.ContentState?
    private var revision = 0
    private var worker: Task<Void, Never>?

    func refresh() {
        let core = PlayerCore.shared
        synchronize(track: core.currentTrack, playing: core.isPlaying, elapsed: core.progress, duration: core.duration)
    }

    func synchronize(track: Track?, playing: Bool, elapsed: Double, duration: Double) {
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        guard Self.isEmbedded, enabled, ActivityAuthorizationInfo().areActivitiesEnabled, let track else {
            guard current != nil || !Activity<SonivoActivityAttributes>.activities.isEmpty else { return }
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
                let activities = Activity<SonivoActivityAttributes>.activities
                if self.current == nil { self.current = activities.first }
                for extra in activities where extra.id != self.current?.id {
                    await extra.end(nil, dismissalPolicy: .immediate)
                }
                if let state {
                    let content = ActivityContent(state: state, staleDate: state.isPlaying ? state.timelineEnd : nil)
                    if let activity = self.current, activity.activityState == .dismissed, activity.content.state.playbackID == state.playbackID {
                        // Respect a user dismissal until the next track; no automatic re-request.
                    } else if let activity = self.current, activity.activityState == .active || activity.activityState == .stale {
                        await activity.update(content)
                    } else if state.isPlaying, UIApplication.shared.applicationState == .active {
                        do {
                            self.current = try Activity.request(attributes: SonivoActivityAttributes(brand: "Sonivo"),
                                content: content, pushType: nil)
                        } catch {
                            SonivoDiagnostics.log("Live Activity request unavailable", tag: "UI")
                            self.previous = nil // Allow a later foreground retry, never a tight loop.
                        }
                    } else { self.previous = nil }
                } else {
                    if let activity = self.current { await activity.end(nil, dismissalPolicy: .immediate) }
                    self.current = nil
                }
                if version == self.revision { break }
            }
        }
    }
}
