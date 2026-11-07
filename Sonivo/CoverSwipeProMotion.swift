import QuartzCore
import SwiftUI
import UIKit

/// Keeps a no-op CADisplayLink alive while the cover is dragged / settling so
/// ProMotion stays near 120 Hz (CADisableMinimumFrameDurationOnPhone alone is
/// not enough for custom DragGesture updates — same pattern as Smooth-Drag).
struct CoverSwipeProMotionGate: UIViewRepresentable {
    var active: Bool

    func makeUIView(context: Context) -> CoverSwipeProMotionView {
        CoverSwipeProMotionView()
    }

    func updateUIView(_ view: CoverSwipeProMotionView, context: Context) {
        view.setActive(active)
    }

    static func dismantleUIView(_ view: CoverSwipeProMotionView, coordinator: ()) {
        view.setActive(false)
    }
}

final class CoverSwipeProMotionView: UIView {
    private final class Tick: NSObject {
        @objc func fire(_ link: CADisplayLink) { /* frame-rate request only */ }
    }

    private let tick = Tick()
    private var link: CADisplayLink?
    private var wantedFPS = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    func setActive(_ active: Bool) {
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        if link == nil {
            let link = CADisplayLink(target: tick, selector: #selector(Tick.fire(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        configureRate()
    }

    private func configureRate() {
        let maximum = window?.windowScene?.screen.maximumFramesPerSecond
            ?? UIScreen.main.maximumFramesPerSecond
        let desired = min(120, max(60, maximum))
        guard desired != wantedFPS else { return }
        wantedFPS = desired
        link?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(min(80, desired)),
            maximum: Float(desired),
            preferred: Float(desired)
        )
    }

    private func stop() {
        link?.invalidate()
        link = nil
        wantedFPS = 0
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, link != nil {
            configureRate()
        }
    }

    deinit {
        link?.invalidate()
    }
}
