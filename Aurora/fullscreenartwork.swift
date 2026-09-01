import AVFoundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class ScrubHapticEngine {
    private let impact = UIImpactFeedbackGenerator(style: .soft)
    private var lastPosition: Double = 0
    private var lastPulsePosition: Double = 0
    private var lastSampleTime = CACurrentMediaTime()
    private var lastPulseTime = 0.0

    func begin(at position: Double) {
        lastPosition = position
        lastPulsePosition = position
        lastSampleTime = CACurrentMediaTime()
        lastPulseTime = 0
        impact.prepare()
    }

    func update(to position: Double, enabled: Bool) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(now - lastSampleTime, 1.0 / 120.0)
        let mediaVelocity = abs(position - lastPosition) / elapsed
        let distance = abs(position - lastPulsePosition)
        let normalized = min(max(mediaVelocity / 90.0, 0), 1)
        let distanceStep = 1.8 - (1.25 * normalized)
        let minimumInterval = 0.085 - (0.050 * normalized)

        if distance >= distanceStep && now - lastPulseTime >= minimumInterval {
            impact.impactOccurred(intensity: 0.28 + (0.62 * normalized))
            impact.prepare()
            lastPulsePosition = position
            lastPulseTime = now
        }
        lastPosition = position
        lastSampleTime = now
    }

    func end(enabled: Bool) {
        guard enabled else { return }
        impact.impactOccurred(intensity: 0.72)
    }
}

/// Silent looping video shot behind the full screen player.
///
/// The surface stays fully transparent until the first frame is actually
/// ready, so a slow or missing video never leaves a black rectangle over the
/// artwork underneath it.
struct FullScreenArtworkVideo: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        context.coordinator.attach(to: view, url: url)
        return view
    }

    func updateUIView(_ view: PlayerSurfaceView, context: Context) {
        context.coordinator.attach(to: view, url: url)
    }

    static func dismantleUIView(_ uiView: PlayerSurfaceView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?
        private var readyObservation: NSKeyValueObservation?
        private var lifecycleObservers: [NSObjectProtocol] = []
        private weak var surface: PlayerSurfaceView?

        func attach(to view: PlayerSurfaceView, url: URL) {
            surface = view

            guard currentURL != url || player == nil else {
                view.playerLayer.player = player
                return
            }

            stop()
            currentURL = url

            let item = AVPlayerItem(url: url)
            item.preferredMaximumResolution = CGSize(width: 720, height: 1280)
            item.preferredPeakBitRate = 2_500_000
            item.preferredForwardBufferDuration = 2

            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.actionAtItemEnd = .advance
            queue.automaticallyWaitsToMinimizeStalling = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            // The video shot must never touch the audio session or the music.
            queue.audiovisualBackgroundPlaybackPolicy = .pauses

            let loop = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            looper = loop

            view.playerLayer.player = queue
            view.playerLayer.opacity = 0

            // Only reveal the layer once a frame exists, and give up quietly if
            // the video shot fails so the still artwork keeps showing.
            readyObservation = queue.observe(\.currentItem?.status, options: [.initial, .new]) { [weak self] observed, _ in
                Task { @MainActor in
                    guard let self, self.player === observed else { return }
                    switch observed.currentItem?.status {
                    case .readyToPlay:
                        self.reveal()
                    case .failed:
                        self.stop()
                    default:
                        break
                    }
                }
            }

            observeLifecycle()
            queue.play()
        }

        private func reveal() {
            guard let layer = surface?.playerLayer, layer.opacity < 1 else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.35
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "reveal")
            layer.opacity = 1
        }

        private func observeLifecycle() {
            let center = NotificationCenter.default
            lifecycleObservers.append(
                center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor [weak self] in self?.player?.pause() }
                }
            )
            lifecycleObservers.append(
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                    Task { @MainActor [weak self] in self?.player?.play() }
                }
            )
        }

        func stop() {
            readyObservation?.invalidate()
            readyObservation = nil
            for observer in lifecycleObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            lifecycleObservers.removeAll()
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            currentURL = nil
            surface?.playerLayer.player = nil
            surface?.playerLayer.opacity = 0
        }
    }
}

final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.opacity = 0
        backgroundColor = .clear
        isOpaque = false
    }
}
