import SwiftUI
import CoreHaptics
import QuartzCore

/// A short, native brand reveal after Apple's static launch screen. RootView mounts immediately.
struct SonivoLaunchHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var themeManager = ThemeFontManager.shared
    @State private var player = PlayerCore.shared
    @State private var startupClaimed = false
    @State private var session = SonivoLaunchSession()
    @State private var epoch: TimeInterval = 0
    @State private var haptics = SonivoLaunchHaptics()
    @State private var brandFontName: String?
    @State private var revealingHome = false

    private var isShowingIntro: Bool { session.hasStarted && !session.isFinished }

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
                SonivoLaunchIntro(epoch: epoch, reduceMotion: reduceMotion,
                                  brandFontName: brandFontName,
                                  exitBlurRadius: revealingHome ? SonivoLaunchMotion.exitDefocusRadius : 0)
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
                brandFontName = SonivoLaunchTypography.prepare()
                epoch = haptics.start(reduceMotion: reduceMotion)
                if !reduceMotion {
                    // Handoff overlaps the final part of the finite Resonance timeline.
                    let untilHandoff = max(0, epoch + SonivoLaunchMotion.fadeStart - CACurrentMediaTime())
                    try await Task.sleep(for: .seconds(untilHandoff))
                    try Task.checkCancellation()
                    guard !session.isFinished, scenePhase == .active else { return }
                    withAnimation(.timingCurve(0.77, 0, 0.175, 1,
                                              duration: SonivoLaunchMotion.exitTransitionDuration)) {
                        revealingHome = true
                    }
                }
                let remaining = reduceMotion ? SonivoLaunchMotion.reducedDuration
                    : max(0, epoch + SonivoLaunchMotion.duration - CACurrentMediaTime())
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
        withTransaction(transaction) { session.finish() }
    }
}

/// The native visual scene has no playback, network access or independent clocks.
private struct SonivoLaunchIntro: View {
    let epoch: TimeInterval
    let reduceMotion: Bool
    let brandFontName: String?
    let exitBlurRadius: Double
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        GeometryReader { geometry in
            let unit = min(1.3, min(geometry.size.width / 390, geometry.size.height / 844))
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || scenePhase != .active)) { _ in
                let time = reduceMotion ? SonivoLaunchMotion.reducedPreviewTime
                    : (epoch > 0 ? max(0, CACurrentMediaTime() - epoch) : 0)
                ZStack {
                    Color(red: 16.0 / 255, green: 16.0 / 255, blue: 16.0 / 255).ignoresSafeArea()
                    let symbolSize = min(geometry.size.width * 0.833, geometry.size.height * 0.385)
                    SonivoResonanceSymbol(time: time, size: symbolSize, reduceMotion: reduceMotion)
                        .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.4023)
                    SonivoLaunchWordmark(time: time, width: geometry.size.width - 48 * unit,
                                         unit: unit, brandFontName: brandFontName, reduceMotion: reduceMotion)
                        .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.635)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("Музыка, которую чувствуешь.")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0.73, green: 0.68, blue: 0.67))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .opacity(reduceMotion ? 1 : SonivoLaunchMotion.taglineOpacity(at: time))
                            .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.708)
                    }
                }
                .opacity(reduceMotion ? 1 : SonivoLaunchMotion.opacity(at: time))
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
            let events = zip(SonivoLaunchMotion.hapticOnsets, SonivoLaunchMotion.hapticStrengths)
                .enumerated().map { index, cue in
                    CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: cue.1),
                        CHHapticEventParameter(parameterID: .hapticSharpness,
                                               value: SonivoLaunchMotion.hapticSharpnesses[index])
                    ], relativeTime: cue.0)
                }
            // A finite, substantial travel rumble follows the close-up settling motion.
            let travelOnset = SonivoLaunchMotion.hapticTravelOnset
            let travelDuration = SonivoLaunchMotion.hapticTravelDuration
            let travel = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            ], relativeTime: travelOnset, duration: travelDuration)
            let travelCurve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.55),
                .init(relativeTime: 0.14, value: 0.90),
                .init(relativeTime: 0.46, value: 0.70),
                .init(relativeTime: 0.82, value: 1),
                .init(relativeTime: travelDuration, value: 0),
                .init(relativeTime: travelDuration + 0.004, value: 1)
            ], relativeTime: travelOnset)
            // Strong decaying bodies give the fixation and wordmark real weight.
            let tailOnsets = [SonivoLaunchMotion.hapticOnsets[0] + 0.015,
                              SonivoLaunchMotion.hapticOnsets[1] + 0.012]
            let tailDurations = [0.260, 0.140]
            let tailStrengths: [Float] = [0.95, 0.80]
            let tails = tailOnsets.indices.map { index in
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: tailStrengths[index]),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.18)
                ], relativeTime: tailOnsets[index], duration: tailDurations[index])
            }
            let curves = tailOnsets.indices.map { index in
                CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                    .init(relativeTime: 0, value: 1),
                    .init(relativeTime: tailDurations[index] * 0.7, value: 0.35),
                    .init(relativeTime: tailDurations[index], value: 0),
                    .init(relativeTime: tailDurations[index] + 0.004, value: 1)
                ], relativeTime: tailOnsets[index])
            }
            let pattern = try CHHapticPattern(events: [travel] + events + tails, parameterCurves: [travelCurve] + curves)
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
