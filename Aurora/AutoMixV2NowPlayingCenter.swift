@preconcurrency import MediaPlayer
import Foundation
import UIKit

private final class NowPlayingArtworkProvider: @unchecked Sendable {
    private let image: UIImage
    nonisolated init(image: UIImage) { self.image = image }
    nonisolated func makeArtwork() -> MPMediaItemArtwork {
        let image = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

@MainActor
final class AutoMixV2NowPlayingCenter {
    static let shared = AutoMixV2NowPlayingCenter()
    private var updateTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: UUID?
    private var artwork: MPMediaItemArtwork?
    private var imageCache: [String: UIImage] = [:]
    private var ownsNowPlaying = false
    private var fullPlayerVisible = false
    private var applicationIsActive = true
    private init() {}

    func setApplicationSceneActive(_ active: Bool) {
        guard applicationIsActive != active else { return }
        applicationIsActive = active
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func install() {
        guard updateTask == nil else { return }
        AutoMixV2AnalysisRuntime.shared.install()
        PlaybackSessionPersistence.shared.install()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await ContinuousClock().sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
    }

    func setFullPlayerVisible(_ visible: Bool) {
        fullPlayerVisible = visible
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    private func refresh() async {
        let runtime = AutoMixV2Runtime.shared
        guard PlaybackCommandRouter.shared.owner == .autoMixV2,
              let track = runtime.currentTrack else {
            clearOnlyIfOwned()
            return
        }

        loadArtwork(for: track)

        // Inside the active app the native player is authoritative. As soon as
        // the app backgrounds, publish the exact audible track and its position.
        if applicationIsActive && runtime.isPlaying {
            suppressSystemSurfacePreservingArtwork()
            return
        }

        let timeline = await runtime.playbackTimeline()
        guard runtime.currentTrack?.id == track.id else { return }
        let duration = max(0, timeline?.duration ?? track.duration)
        let elapsed = min(max(0, timeline?.position ?? 0),
                          duration > 0 ? duration : .greatestFiniteMagnitude)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: runtime.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExternalContentIdentifier: "sonivo://track/\(track.id.uuidString)"
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyPlaybackProgress] = elapsed / duration
        }
        if let currentIndex = runtime.playbackQueue.firstIndex(where: { $0.id == track.id }) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = runtime.playbackQueue.count
        }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if artworkTrackID == track.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = runtime.isPlaying ? .playing : .paused
        ownsNowPlaying = true
    }

    private func loadArtwork(for track: Track) {
        guard artworkTrackID != track.id else { return }
        artworkTask?.cancel()
        artworkTrackID = track.id
        artwork = nil
        guard let raw = track.coverURL, let url = URL(string: raw) else { return }
        if let image = imageCache[raw] {
            artwork = NowPlayingArtworkProvider(image: image).makeArtwork()
            return
        }
        let id = track.id
        artworkTask = Task { @MainActor [weak self] in
            guard let self,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data),
                  self.artworkTrackID == id,
                  AutoMixV2Runtime.shared.currentTrack?.id == id else { return }
            self.imageCache[raw] = image
            self.artwork = NowPlayingArtworkProvider(image: image).makeArtwork()
            await self.refresh()
        }
    }

    private func suppressSystemSurfacePreservingArtwork() {
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo != nil || center.playbackState != .stopped {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        ownsNowPlaying = false
    }

    private func clearOnlyIfOwned() {
        guard ownsNowPlaying else { return }
        suppressSystemSurfacePreservingArtwork()
        artworkTask?.cancel()
        artworkTask = nil
        artworkTrackID = nil
        artwork = nil
    }
}
