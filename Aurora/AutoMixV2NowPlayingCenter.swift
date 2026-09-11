@preconcurrency import MediaPlayer
import Foundation
import UIKit

private final class NowPlayingArtworkProvider: @unchecked Sendable {
    private let image: UIImage
    nonisolated init(image: UIImage) { self.image = image }
    nonisolated func makeArtwork() -> MPMediaItemArtwork { let image = image; return MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
}

@MainActor
final class AutoMixV2NowPlayingCenter {
    static let shared = AutoMixV2NowPlayingCenter()
    private var updateTask: Task<Void, Never>?; private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: UUID?; private var artwork: MPMediaItemArtwork?
    private var imageCache: [String: UIImage] = [:]; private var ownsNowPlaying = false
    private init() {}
    func install() {
        guard updateTask == nil else { return }
        AutoMixV2AnalysisRuntime.shared.install(); PlaybackSessionPersistence.shared.install()
        updateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled { await self?.refresh(); do { try await ContinuousClock().sleep(for: .milliseconds(500)) } catch { return } }
        }
    }
    private func refresh() async {
        let runtime = AutoMixV2Runtime.shared
        guard AutoMixEngineSelectionStore.shared.isV2Enabled, let track = runtime.currentTrack else { clearOnlyIfOwned(); return }
        loadArtwork(for: track)
        let timeline = await runtime.playbackTimeline(); let d = max(0, timeline?.duration ?? track.duration)
        let p = min(max(0, timeline?.position ?? 0), d > 0 ? d : .greatestFiniteMagnitude)
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p, MPNowPlayingInfoPropertyPlaybackRate: runtime.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false]
        if d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d; info[MPNowPlayingInfoPropertyPlaybackProgress] = p / d }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if artworkTrackID == track.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default(); center.nowPlayingInfo = info
        center.playbackState = runtime.isPlaying ? .playing : .paused; ownsNowPlaying = true
    }
    private func loadArtwork(for track: Track) {
        guard artworkTrackID != track.id else { return }
        artworkTask?.cancel(); artworkTrackID = track.id; artwork = nil
        guard let raw = track.coverURL, let url = URL(string: raw) else { return }
        if let image = imageCache[raw] { artwork = NowPlayingArtworkProvider(image: image).makeArtwork(); return }
        let id = track.id
        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = UIImage(data: data), artworkTrackID == id else { return }
            imageCache[raw] = image; artwork = NowPlayingArtworkProvider(image: image).makeArtwork()
        }
    }
    private func clearOnlyIfOwned() {
        guard ownsNowPlaying else { return }
        let center = MPNowPlayingInfoCenter.default(); center.nowPlayingInfo = nil; center.playbackState = .stopped
        ownsNowPlaying = false; artworkTask?.cancel(); artworkTask = nil; artworkTrackID = nil; artwork = nil
    }
}
