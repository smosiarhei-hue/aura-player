import SwiftUI
import UIKit
import QuartzCore
import Observation

/// Only the active word reads frameTime. The scrolling list observes selection,
/// which changes at a line boundary, rather than rebuilding its layout at 120 Hz.
@Observable @MainActor
final class LyricsDisplayClock {
    private(set) var frameTime: Double = 0
    private(set) var activeIndex: Int?

    func sample(time: Double, selection: Int?) {
        guard time.isFinite, time >= 0 else { return }
        frameTime = time
        if activeIndex != selection { activeIndex = selection }
    }
}

@MainActor private final class LyricsDisplaySurface: UIView {
    var environmentChanged: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        environmentChanged?()
    }
}

@MainActor private final class LyricsDisplayTarget: NSObject {
    weak var owner: LyricsFrameDriver.Coordinator?
    init(_ owner: LyricsFrameDriver.Coordinator) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.tick() }
}

/// Requests ProMotion on the actual window screen. This link never advances time
/// by itself: every frame samples the playback clock, including stalls and seeks.
struct LyricsFrameDriver: UIViewRepresentable {
    let clock: LyricsDisplayClock
    let running: Bool
    let frameLimit: Int
    let sampleTime: @MainActor () -> Double
    let selectLine: @MainActor (Double) -> Int?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = LyricsDisplaySurface()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        view.environmentChanged = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.refresh(view)
        }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.clock = clock
        coordinator.running = running
        coordinator.frameLimit = frameLimit
        coordinator.sampleTime = sampleTime
        coordinator.selectLine = selectLine
        coordinator.refresh(view)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stop()
        (view as? LyricsDisplaySurface)?.environmentChanged = nil
    }

    @MainActor final class Coordinator {
        weak var clock: LyricsDisplayClock?
        var running = false
        var frameLimit = 120
        var sampleTime: (@MainActor () -> Double)?
        var selectLine: (@MainActor (Double) -> Int?)?
        private var link: CADisplayLink?
        private var target: LyricsDisplayTarget?
        private var requestedFPS = 0

        func refresh(_ view: UIView) {
            guard running, let screen = view.window?.windowScene?.screen else { stop(); return }
            let desired = max(1, min(frameLimit, screen.maximumFramesPerSecond))
            if link == nil {
                let target = LyricsDisplayTarget(self)
                let link = CADisplayLink(target: target, selector: #selector(LyricsDisplayTarget.tick(_:)))
                self.target = target
                self.link = link
                link.add(to: .main, forMode: .common)
            }
            if requestedFPS != desired {
                requestedFPS = desired
                link?.preferredFrameRateRange = CAFrameRateRange(
                    minimum: Float(min(60, desired)), maximum: Float(desired), preferred: Float(desired))
            }
        }
        func tick() {
            guard running, let sampleTime else { return }
            let time = sampleTime()
            clock?.sample(time: time, selection: selectLine?(time))
        }
        func stop() {
            link?.invalidate()
            link = nil
            target = nil
            requestedFPS = 0
        }
    }
}
