import SwiftUI
import CoreHaptics
import QuartzCore

/// A short, native brand reveal after Apple's static launch screen. RootView mounts immediately.
struct SonivoLaunchHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var themeManager = ThemeFontManager.shared
    @State private var player = PlayerCore.shared
    // This state is initialized before the first body evaluation, not by .task.
    @State private var launchDecisionPending = !SonivoLaunchLifetime.shared.hasClaimed
    @State private var startupClaimed = false
    @State private var session = SonivoLaunchSession()
    @State private var epoch: TimeInterval = 0
    @State private var haptics = SonivoLaunchHaptics()
    @State private var revealingHome = false

    private var isShowingIntro: Bool {
        session.shouldCoverHome(pendingDecision: launchDecisionPending, isPlaying: player.isPlaying)
    }

    var body: some View {
        ZStack {
            RootView(onExternalPlaybackOpen: finish).tint(SN.accent)
                .modifier(SonivoLaunchHomeReveal(
                    progress: !isShowingIntro || revealingHome ? 1 : 0,
                    reduceMotion: reduceMotion
                ))
                .allowsHitTesting(!isShowingIntro || revealingHome)
                .accessibilityHidden(isShowingIntro && !revealingHome)
            if isShowingIntro {
                SonivoLaunchIntro(epoch: epoch, reduceMotion: reduceMotion)
                    .allowsHitTesting(!revealingHome)
                    .transition(.identity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(themeManager.appearance.colorScheme)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                if startupClaimed { finish() }
                return
            }
            guard !session.isFinished, SonivoLaunchLifetime.shared.claim() else {
                finish()
                return
            }
            startupClaimed = true
            do {
                // Every cold launch gets the finite brand reveal, even with a warm
                // library cache. Root and account restoration still start immediately.
                try Task.checkCancellation()
                guard scenePhase == .active,
                      session.begin(isActive: true, isPlaying: player.isPlaying) else {
                    finish()
                    return
                }
                launchDecisionPending = false
                epoch = haptics.start(reduceMotion: reduceMotion)
                if !reduceMotion {
                    // Handoff overlaps the final part of the finite S + sound timeline.
                    let untilHandoff = max(0, epoch + SonivoBrandLaunchMotion.fadeStart - CACurrentMediaTime())
                    try await Task.sleep(for: .seconds(untilHandoff))
                    try Task.checkCancellation()
                    guard !session.isFinished, scenePhase == .active else { return }
                    withAnimation(.timingCurve(0.77, 0, 0.175, 1,
                                              duration: SonivoBrandLaunchMotion.exitTransitionDuration)) {
                        revealingHome = true
                    }
                }
                let remaining = reduceMotion ? SonivoBrandLaunchMotion.reducedDuration
                    : max(0, epoch + SonivoBrandLaunchMotion.duration - CACurrentMediaTime())
                try await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                finish()
            } catch {
                finish()
            }
        }
        .task(id: session.isFinished) {
            if session.isFinished { haptics.stop() }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { finish() }
        }
        .onChange(of: reduceMotion) { _, _ in
            // Respect an accessibility preference changed during the reveal immediately.
            if session.hasStarted { finish() }
        }
        .onChange(of: SettingsStore.shared.hapticsEnabled) { _, enabled in
            if !enabled { haptics.stop() }
        }
        .onDisappear { finish() }
    }

    private func finish() {
        haptics.stop()
        // Skip/deep-link/background/playback interruptions never wait for the handoff.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            launchDecisionPending = false
            session.finish()
        }
    }
}

/// The native visual scene has no playback, network access or independent clocks.
private struct SonivoLaunchIntro: View {
    let epoch: TimeInterval
    let reduceMotion: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || scenePhase != .active)) { _ in
                let time = reduceMotion ? SonivoBrandLaunchMotion.reducedPreviewTime
                    : (epoch > 0 ? max(0, CACurrentMediaTime() - epoch) : 0)
                SonivoBrandLaunchScene(time: time, reduceMotion: reduceMotion)
            }
        }
        // Clip against full display bounds, never against the parent safe-area rectangle.
        .clipped()
        .ignoresSafeArea(.container, edges: .all)
        .accessibilityLabel("Sonivo")
        .accessibilityIdentifier("sonivo.launch.intro")
    }
}

/// Dedicated, short-lived haptic-only pattern. Never takes ownership of the music visualizer.
@MainActor
private final class SonivoLaunchHaptics {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?

    func start(reduceMotion: Bool) -> TimeInterval {
        stop()
        guard !reduceMotion, SettingsStore.shared.hapticsEnabled,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return CACurrentMediaTime()
        }
        do {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in Task { @MainActor in self?.stop() } }
            self.engine = engine
            try engine.start()
            let events = zip(SonivoBrandLaunchMotion.hapticOnsets, SonivoBrandLaunchMotion.hapticStrengths)
                .enumerated().map { index, cue in
                    CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: cue.1),
                        CHHapticEventParameter(parameterID: .hapticSharpness,
                                               value: SonivoBrandLaunchMotion.hapticSharpnesses[index])
                    ], relativeTime: cue.0)
                }
            // Medium, transient-only cues: no continuous travel rumble or tails.
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            self.player = player
            // A shared start offset, not two independent animation/haptic timers.
            let lead = 0.035
            let visualEpoch = CACurrentMediaTime() + lead
            try player.start(atTime: engine.currentTime + lead)
            return visualEpoch
        } catch {
            stop()
            return CACurrentMediaTime()
        }
    }
    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop(completionHandler: nil)
        engine = nil
    }
}
