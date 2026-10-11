import AVFoundation
import Combine
import Observation

/// Stable media ownership: subscriptions are installed per asset, not per SwiftUI frame.
@Observable @MainActor
final class VideoShotPlaybackController {
    private(set) var player: AVQueuePlayer?
    private(set) var isReady = false
    private var looper: AVPlayerLooper?
    private var generation = UUID()
    private var statusObservation: AnyCancellable?
    private var failureObservation: AnyCancellable?
    private var enabled = false
    private var matchingTrack = false
    private var musicPlaying = false
    private var sceneActive = false
    private var playerVisible = false
    private var lyricsVisible = false
    private var reduceMotion = false

    func configure(url: URL) {
        teardown()
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = []
        let videoPlayer = AVQueuePlayer()
        videoPlayer.volume = 0
        videoPlayer.isMuted = true
        videoPlayer.actionAtItemEnd = .none
        videoPlayer.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: videoPlayer, templateItem: item)
        player = videoPlayer
        let request = generation
        statusObservation = videoPlayer.publisher(for: \.currentItem, options: [.initial, .new])
            .map { currentItem -> AnyPublisher<AVPlayerItem.Status, Never> in
                guard let currentItem else { return Just(.unknown).eraseToAnyPublisher() }
                return currentItem.publisher(for: \.status, options: [.initial, .new]).eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == request else { return }
                    self.isReady = status == .readyToPlay
                    SonivoDiagnostics.log("Native item status=\(status.rawValue)", tag: "VIDEOSHOT")
                    if status == .failed {
                        if let error = self.player?.currentItem?.error as NSError? {
                            SonivoDiagnostics.log("Native item failed: domain=\(error.domain), code=\(error.code)", tag: "VIDEOSHOT")
                        }
                        self.teardown()
                    }
                    else { self.applyPlaybackState() }
                }
            }
        failureObservation = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .compactMap { ($0.object as? AVPlayerItem).map(ObjectIdentifier.init) }
            .sink { [weak self] failedIdentity in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == request,
                          let currentItem = self.player?.currentItem,
                          ObjectIdentifier(currentItem) == failedIdentity else { return }
                    self.teardown()
                }
            }
    }

    func update(enabled: Bool, matchingTrack: Bool, musicPlaying: Bool, sceneActive: Bool,
                playerVisible: Bool, lyricsVisible: Bool, reduceMotion: Bool) {
        self.enabled = enabled
        self.matchingTrack = matchingTrack
        self.musicPlaying = musicPlaying
        self.sceneActive = sceneActive
        self.playerVisible = playerVisible
        self.lyricsVisible = lyricsVisible
        self.reduceMotion = reduceMotion
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        let shouldPlay = VideoShotPlaybackPolicy.shouldPlay(
            enabled: enabled, ready: isReady, matchingTrack: matchingTrack,
            musicPlaying: musicPlaying, sceneActive: sceneActive, playerVisible: playerVisible,
            lyricsVisible: lyricsVisible, reduceMotion: reduceMotion)
        if shouldPlay { player?.play() } else { player?.pause() }
    }

    func teardown() {
        generation = UUID()
        statusObservation?.cancel(); statusObservation = nil
        failureObservation?.cancel(); failureObservation = nil
        isReady = false
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
    }
}
