import SwiftUI
import CoreHaptics
import QuartzCore

/// A short, native brand reveal after Apple's static launch screen. RootView mounts immediately.
struct SonivoLaunchHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var themeManager = ThemeFontManager.shared
    @State private var player = PlayerCore.shared
    @State private var session = SonivoLaunchSession()
    @State private var epoch: TimeInterval = 0
    @State private var haptics = SonivoLaunchHaptics()
    @State private var brandFontName: String?
    @State private var revealingHome = false

    var body: some View {
        ZStack {
            RootView(onExternalPlaybackOpen: finish).tint(SN.accent)
                .modifier(SonivoLaunchHomeReveal(
                    progress: session.isFinished || revealingHome ? 1 : 0,
                    reduceMotion: reduceMotion
                ))
                .allowsHitTesting(session.isFinished)
                .accessibilityHidden(!session.isFinished)
            if !session.isFinished {
                SonivoLaunchIntro(epoch: epoch, reduceMotion: reduceMotion,
                                  brandFontName: brandFontName,
                                  exitBlurRadius: revealingHome ? SonivoLaunchMotion.exitDefocusRadius : 0,
                                  onSkip: finish)
                    .transition(.identity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(themeManager.appearance.colorScheme)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                if session.hasStarted { finish() }
                return
            }
            guard session.begin(isActive: true, isPlaying: player.isPlaying) else { return }
            brandFontName = SonivoLaunchTypography.prepare()
            epoch = haptics.start(reduceMotion: reduceMotion)
            do {
                if !reduceMotion {
                    // Handoff overlaps the final part of the finite Resonance timeline.
                    let untilHandoff = max(0, epoch + SonivoLaunchMotion.fadeStart - CACurrentMediaTime())
                    try await Task.sleep(for: .seconds(untilHandoff))
                    try Task.checkCancellation()
                    guard !session.isFinished, scenePhase == .active else { return }
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1,
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
                haptics.stop()
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
    let onSkip: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var themeManager = ThemeFontManager.shared

    var body: some View {
        GeometryReader { geometry in
            let unit = min(1.3, min(geometry.size.width / 390, geometry.size.height / 844))
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || scenePhase != .active)) { _ in
                let time = reduceMotion ? SonivoLaunchMotion.reducedPreviewTime
                    : (epoch > 0 ? max(0, CACurrentMediaTime() - epoch) : 0)
                ZStack {
                    themeManager.selectedTheme.darkCanvasColor.ignoresSafeArea()
                    VStack(spacing: 18 * unit) {
                        SonivoResonanceSymbol(time: time, theme: themeManager.selectedTheme,
                                              reduceMotion: reduceMotion)
                            .frame(width: 260 * unit, height: 264 * unit)
                        Text("Sonivo")
                            .font(brandFontName.map { Font.custom($0, fixedSize: 68 * unit) }
                                  ?? .system(size: 68 * unit, weight: .regular, design: .serif))
                            .foregroundStyle(Color(red: 0.94, green: 0.91, blue: 0.89))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .opacity(reduceMotion ? 1 : SonivoLaunchMotion.wordOpacity(at: time))
                            .offset(y: reduceMotion ? 0 : 6 * (1 - SonivoLaunchMotion.wordOpacity(at: time)))
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("Музыка, которую чувствуешь.")
                                .font(.subheadline)
                                .foregroundStyle(Color(red: 0.73, green: 0.68, blue: 0.67))
                                .multilineTextAlignment(.center)
                                .opacity(reduceMotion ? 1 : SonivoLaunchMotion.taglineOpacity(at: time))
                        }
                    }
                    .padding(.horizontal, 24)
                    .blur(radius: reduceMotion ? 0 : exitBlurRadius)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -24 * unit)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sonivo")
                    VStack {
                        Spacer()
                        Button("Пропустить", action: onSkip)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color(red: 0.73, green: 0.68, blue: 0.67))
                            .frame(minWidth: 120, minHeight: 44)
                            .accessibilityHint("Сразу открыть приложение")
                            .padding(.bottom, 16)
                    }
                }
                .opacity(reduceMotion ? 1 : SonivoLaunchMotion.opacity(at: time))
            }
        }
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
            let events = zip(SonivoLaunchMotion.hapticOnsets, SonivoLaunchMotion.hapticStrengths).map { onset, strength in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.30)
                ], relativeTime: onset)
            }
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
