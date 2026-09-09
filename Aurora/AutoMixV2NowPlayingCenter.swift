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
    private var ownsNowPlaying = false
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
        let runtime = AutoMixV2Runtime.shared
        let enabled = AutoMixEngineSelectionStore.shared.isV2Enabled
        guard enabled, let track = runtime.currentTrack else {
            clearOnlyIfOwned(); return
        }
        startArtworkLoadIfNeeded(for: track)
        let timeline = await runtime.playbackTimeline()
        let durationCandidate = timeline?.duration ?? track.duration
        let duration = durationCandidate.isFinite ? max(0, durationCandidate) : 0
        let positionCandidate = timeline?.position ?? 0
        let elapsed = positionCandidate.isFinite ? min(max(0, positionCandidate), duration > 0 ? duration : positionCandidate) : 0
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
            info[MPNowPlayingInfoPropertyPlaybackProgress] = min(1, max(0, elapsed / duration))
        }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if artworkTrackID == track.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = runtime.isPlaying ? .playing : .paused
        ownsNowPlaying = true; publishedTrackID = track.id
    }

    private func startArtworkLoadIfNeeded(for track: Track) {
        guard artworkTrackID != track.id else { return }
        artworkTask?.cancel(); artworkTrackID = track.id; artwork = nil
        guard let raw = track.coverURL, let url = URL(string: raw) else { return }
        if let cached = imageCache[raw] { artwork = makeArtwork(cached); return }
        let id = track.id
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let image = UIImage(data: data), artworkTrackID == id else { return }
                imageCache[raw] = image; artwork = makeArtwork(image)
            } catch { return }
        }
    }
    private func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    private func clearOnlyIfOwned() {
        guard ownsNowPlaying else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil; center.playbackState = .stopped
        ownsNowPlaying = false; publishedTrackID = nil
        artworkTask?.cancel(); artworkTask = nil; artworkTrackID = nil; artwork = nil
    }
}
