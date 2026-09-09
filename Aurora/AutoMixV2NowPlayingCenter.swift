// Path: Aurora/AutoMixV2NowPlayingCenter.swift

@preconcurrency import MediaPlayer
import Foundation
import UIKit

@MainActor
final class AutoMixV2NowPlayingCenter {
    static let shared = AutoMixV2NowPlayingCenter()
    private var updateTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var publishedTrackID: UUID?
    private var artworkTrackID: UUID?
    private var artwork: MPMediaItemArtwork?
    private var imageCache: [String: UIImage] = [:]
    private init() {}

    func install() {
        guard updateTask == nil else { return }
        AutoMixV2AnalysisRuntime.shared.install()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await ContinuousClock().sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func refresh() async {
        let center = MPNowPlayingInfoCenter.default()
        guard AutoMixEngineSelectionStore.shared.isV2Enabled else {
            clear(center); return
        }
        let runtime = AutoMixV2Runtime.shared
        guard let track = runtime.currentTrack else { clear(center); return }

        // Preload artwork while the app is visible so lock screen/Dynamic Island
        // receive it immediately when the app moves to background.
        startArtworkLoadIfNeeded(for: track)

        // iOS owns the system Dynamic Island media surface. Clearing Now Playing
        // while Sonivo is foreground is the supported best-effort way to avoid a
        // duplicate system player over the app's own full player. It is restored
        // within 500 ms after the app is hidden or the device is locked.
        if UIApplication.shared.applicationState == .active {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            publishedTrackID = nil
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
        if artworkTrackID == track.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = runtime.isPlaying ? .playing : .paused
        publishedTrackID = track.id
    }

    private func startArtworkLoadIfNeeded(for track: Track) {
        guard artworkTrackID != track.id else { return }
        artworkTask?.cancel(); artworkTask = nil
        artworkTrackID = track.id; artwork = nil
        guard let raw = track.coverURL, let url = URL(string: raw) else { return }
        if let cached = imageCache[raw] { artwork = makeArtwork(cached); return }
        let id = track.id
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let image = UIImage(data: data) else { return }
                guard artworkTrackID == id else { return }
                imageCache[raw] = image
                artwork = makeArtwork(image)
            } catch is CancellationError { return }
            catch let error as URLError where error.code == .cancelled { return }
            catch { return } // Artwork failure must never affect audio playback.
        }
    }

    private func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func clear(_ center: MPNowPlayingInfoCenter) {
        artworkTask?.cancel(); artworkTask = nil
        center.nowPlayingInfo = nil; center.playbackState = .stopped
        publishedTrackID = nil; artworkTrackID = nil; artwork = nil
    }
}
