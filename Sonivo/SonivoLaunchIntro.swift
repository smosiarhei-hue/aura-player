import SwiftUI
import CoreHaptics
import QuartzCore

/// A short, native brand reveal after Apple's static launch screen. RootView mounts immediately.
struct SonivoLaunchHost: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = PlayerCore.shared
    @State private var session = SonivoLaunchSession()
    @State private var epoch: TimeInterval = 0
    @State private var haptics = SonivoLaunchHaptics()

    var body: some View {
        ZStack {
            RootView(onExternalPlaybackOpen: finish).tint(SN.accent)
                .allowsHitTesting(session.isFinished)
                .accessibilityHidden(!session.isFinished)
            if !session.isFinished {
                SonivoLaunchIntro(epoch: epoch, reduceMotion: reduceMotion, onSkip: finish)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.isFinished)
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                if session.hasStarted { finish() }
                return
            }
            guard session.begin(isActive: true, isPlaying: player.isPlaying) else { return }
            epoch = haptics.start(reduceMotion: reduceMotion)
            do {
                let remaining = reduceMotion ? SonivoLaunchMotion.reducedDuration
                    : max(0, epoch + SonivoLaunchMotion.duration - CACurrentMediaTime())
                try await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                finish()
            } catch {
                haptics.stop()
            }
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
        session.finish()
    }
}

private struct SonivoLaunchIntro: View {
    let epoch: TimeInterval
    let reduceMotion: Bool
    let onSkip: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || scenePhase != .active)) { _ in
            let time = reduceMotion ? 1.30 : (epoch > 0 ? max(0, CACurrentMediaTime() - epoch) : 0)
            GeometryReader { geometry in
                let unit = Double(min(1.3, min(geometry.size.width / 390, geometry.size.height / 844)))
                ZStack {
                    SN.bg.ignoresSafeArea()
                    VStack(spacing: 26 * unit) {
                        soundMark(time: time, unit: unit)
                            .frame(width: 180 * unit, height: 120 * unit)
                            .accessibilityHidden(true)
                        HStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { index in
                                let reveal = SonivoLaunchMotion.letterProgress(at: time, index: index)
                                Text(SonivoLaunchMotion.brandLetters[index])
                                    .font(.system(size: 62 * unit, weight: .black, design: .rounded))
                                    .foregroundStyle(SN.ink)
                                    .offset(y: reduceMotion ? 0 : (1 - reveal) * 22 * unit)
                                    .opacity(reveal)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Sonivo")
                        Text("Музыка, которую чувствуешь.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(SN.inkMuted)
                            .multilineTextAlignment(.center)
                            .opacity(SonivoLaunchMotion.easeOut(SonivoLaunchMotion.progress(time, from: 1.02, duration: 0.22)))
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -28 * unit)
                    VStack {
                        Spacer()
                        Button("Пропустить", action: onSkip)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(SN.inkMuted)
                            .frame(minWidth: 120, minHeight: 44)
                            .accessibilityHint("Сразу открыть приложение")
                            .padding(.bottom, 16)
                    }
                }
            }
            .opacity(reduceMotion ? 1 : SonivoLaunchMotion.opacity(at: time))
        }
        .accessibilityIdentifier("sonivo.launch.intro")
    }

    private func soundMark(time: Double, unit: Double) -> some View {
        let accent = SonivoLaunchMotion.accentVisibility(at: time)
        return ZStack {
            Circle()
                .stroke(SN.accent.opacity(accent * 0.32), lineWidth: 1.5)
                .frame(width: 108 * unit, height: 108 * unit)
                .scaleEffect(reduceMotion ? 1 : 0.94 + SonivoLaunchMotion.progress(time, from: 0.48, duration: 0.44) * 0.32)
            ForEach(0..<5, id: \.self) { index in
                let reveal = SonivoLaunchMotion.markProgress(at: time, index: index)
                let drift = Double(index - 2) * 25 * (1 - reveal)
                Capsule()
                    .fill(LinearGradient(colors: [SN.accent, SN.ember], startPoint: .top, endPoint: .bottom))
                    .frame(width: 11 * unit, height: SonivoLaunchMotion.markHeights[index] * unit)
                    .scaleEffect(y: reduceMotion ? 1 : 0.92 + reveal * 0.08)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(index - 2) * 9 * (1 - reveal)))
                    .offset(x: (Double(index - 2) * 21 + (reduceMotion ? 0 : drift)) * unit,
                            y: reduceMotion ? 0 : (index.isMultiple(of: 2) ? 14 : -14) * (1 - reveal) * unit)
                    .opacity(0.15 + reveal * 0.85)
            }
        }
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
