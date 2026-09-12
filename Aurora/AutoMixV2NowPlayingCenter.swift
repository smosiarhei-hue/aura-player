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
    private init() {}

    func install() {
        guard updateTask == nil else { return }
        AutoMixV2AnalysisRuntime.shared.install()
        PlaybackSessionPersistence.shared.install()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await ContinuousClock().sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    func setFullPlayerVisible(_ visible: Bool) {
        fullPlayerVisible = visible
        if UIApplication.shared.applicationState == .active {
            suppressSystemSurfacePreservingArtwork()
        } else {
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    private func refresh() async {
        let runtime = AutoMixV2Runtime.shared
        guard AutoMixEngineSelectionStore.shared.isV2Enabled,
              let track = runtime.currentTrack else {
            clearOnlyIfOwned()
            return
        }

        // Preload and retain artwork while the app is visible so lock-screen and
        // Dynamic Island metadata appear immediately after the app backgrounds.
        loadArtwork(for: track)
        if UIApplication.shared.applicationState == .active {
            suppressSystemSurfacePreservingArtwork()
            return
        }

        let timeline = await runtime.playbackTimeline()
        let duration = max(0, timeline?.duration ?? track.duration)
        let elapsed = min(max(0, timeline?.position ?? 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: runtime.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyPlaybackProgress] = elapsed / duration
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
        artworkTask?.cancel(); artworkTrackID = track.id; artwork = nil
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
                  let image = UIImage(data: data), artworkTrackID == id else { return }
            imageCache[raw] = image
            artwork = NowPlayingArtworkProvider(image: image).makeArtwork()
        }
    }

    private func suppressSystemSurfacePreservingArtwork() {
        guard ownsNowPlaying else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        ownsNowPlaying = false
    }

    private func clearOnlyIfOwned() {
        guard ownsNowPlaying else { return }
        suppressSystemSurfacePreservingArtwork()
        artworkTask?.cancel(); artworkTask = nil; artworkTrackID = nil; artwork = nil
    }
}
