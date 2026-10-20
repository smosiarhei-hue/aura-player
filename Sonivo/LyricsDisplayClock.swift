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
    @objc func tick(_ link: CADisplayLink) { owner?.tick(at: link.timestamp) }
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
        private var lastFrameTimestamp: CFTimeInterval?
        private var lastGapWarning: CFTimeInterval = 0

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
        func tick(at timestamp: CFTimeInterval) {
            guard running, let sampleTime else { return }
            let time = sampleTime()
            // Local evidence of a stalled UI, not an invented source/vocal offset.
            if let previous = lastFrameTimestamp, timestamp - previous > 0.15,
               timestamp - lastGapWarning > 10 {
                lastGapWarning = timestamp
                SonivoDiagnostics.log("Lyrics display gap: ms=\(Int((timestamp - previous) * 1000)), position=\(time)", tag: "LYRICS")
            }
            lastFrameTimestamp = timestamp
            clock?.sample(time: time, selection: selectLine?(time))
        }
        func stop() {
            link?.invalidate()
            link = nil
            target = nil
            requestedFPS = 0
            lastFrameTimestamp = nil
        }
    }
}

/// One scheduling/lifecycle policy for Typography, Lines and Staggered. Progress
/// notifications refresh only stopped/reduced-motion views; running text samples
/// the actual audio source on display frames, never queued periodic-observer time.
struct LyricsClockSurface: View {
    let clock: LyricsDisplayClock
    let player: ActivePlayerPresentation
    let lyrics: Lyrics
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermal = ProcessInfo.processInfo.thermalState

    private var frameLimit: Int {
        if thermal == .critical { return 15 }
        return lowPower || thermal == .serious ? 30 : 120
    }
    private var running: Bool {
        player.isPlaying && !player.isBuffering && lyrics.isSynchronized && scenePhase == .active && !reduceMotion
    }
    private func refresh() {
        let time = LyricsPlaybackClock.time(for: player)
        clock.sample(time: time, selection: TypographyLyricsPolicy.activeIndex(lines: lyrics.lines,
            synchronized: lyrics.isSynchronized, time: time, duration: player.duration))
    }
    var body: some View {
        LyricsFrameDriver(clock: clock, running: running, frameLimit: frameLimit,
            sampleTime: { LyricsPlaybackClock.time(for: player) },
            selectLine: { time in TypographyLyricsPolicy.activeIndex(lines: lyrics.lines,
                synchronized: lyrics.isSynchronized, time: time, duration: player.duration) })
            .frame(width: 0, height: 0).accessibilityHidden(true)
            .onAppear { refresh() }
            .onChange(of: lyrics) { _, _ in refresh() }
            .onChange(of: clock.activeIndex) { _, index in
                guard let index, lyrics.lines.indices.contains(index) else { return }
                let line = lyrics.lines[index]
                SonivoDiagnostics.log("Lyrics boundary: source=\(lyrics.sourceName), backend=\(player.usesStreamingBackend ? "stream" : "native"), row=\(index), clock=\(clock.frameTime), lineStart=\(line.startTime), firstWord=\(line.words?.first?.startTime ?? line.startTime)", tag: "LYRICS")
            }
            .onChange(of: player.currentTrack?.id) { _, _ in refresh() }
            .onChange(of: player.isPlaying) { _, _ in refresh() }
            .onChange(of: player.isBuffering) { _, _ in refresh() }
            .onChange(of: running ? 0 : player.progress) { _, _ in refresh() }
            .onChange(of: reduceMotion) { _, _ in refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                thermal = ProcessInfo.processInfo.thermalState
            }
    }
}
