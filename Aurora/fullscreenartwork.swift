import AVFoundation
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

        // Slow scrubbing produces distinct soft ticks. Fast scrubbing produces
        // closer, sharper ticks so the finger can feel the scrub velocity.
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

    final class Coordinator {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?

        func attach(to view: PlayerSurfaceView, url: URL) {
            guard currentURL != url || player == nil else {
                view.playerLayer.player = player
                return
            }
            stop()
            currentURL = url
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.actionAtItemEnd = .advance
            queue.preventsDisplaySleepDuringVideoPlayback = false
            let loop = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            looper = loop
            view.playerLayer.player = queue
            queue.play()
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            currentURL = nil
        }
    }
}

final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }
}
