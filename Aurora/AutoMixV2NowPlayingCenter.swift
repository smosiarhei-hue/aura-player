// Path: Aurora/AutoMixV2NowPlayingCenter.swift

@preconcurrency import MediaPlayer
import Foundation

@MainActor
final class AutoMixV2NowPlayingCenter {
    static let shared = AutoMixV2NowPlayingCenter()
    private var updateTask: Task<Void, Never>?
    private var publishedTrackID: UUID?
    private init() {}

    func install() {
        guard updateTask == nil else { return }
        AutoMixV2AnalysisRuntime.shared.install()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await ContinuousClock().sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func refresh() async {
        guard AutoMixEngineSelectionStore.shared.isV2Enabled else {
            publishedTrackID = nil
            return
        }
        let runtime = AutoMixV2Runtime.shared
        guard let track = runtime.currentTrack else {
            if publishedTrackID != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                publishedTrackID = nil
            }
            return
        }
        let timeline = await runtime.playbackTimeline()
        let duration = timeline?.duration ?? max(0, track.duration)
        let elapsed = min(max(0, timeline?.position ?? 0), max(duration, 0))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: runtime.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = runtime.isPlaying ? .playing : .paused
        publishedTrackID = track.id
    }
}
