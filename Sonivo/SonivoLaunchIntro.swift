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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || scenePhase != .active)) { _ in
            let time = reduceMotion ? SonivoLaunchMotion.reducedPreviewTime : (epoch > 0 ? max(0, CACurrentMediaTime() - epoch) : 0)
            GeometryReader { geometry in
                let unit = Double(min(1.3, min(geometry.size.width / 390, geometry.size.height / 844)))
                ZStack {
                    SN.bg.ignoresSafeArea()
                    VStack(spacing: 26 * unit) {
                        soundMark(time: time, unit: unit)
                            .frame(width: 180 * unit, height: 120 * unit)
                            .accessibilityHidden(true)
                        wordmark(time: time, unit: unit, highlighted: false)
                            .overlay {
                                if !reduceMotion {
                                    wordmark(time: time, unit: unit, highlighted: true)
                                        .mask {
                                            GeometryReader { bounds in
                                                let stripeWidth = 64 * unit
                                                let travel = Double(bounds.size.width) + stripeWidth
                                                LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                                    .frame(width: stripeWidth)
                                                    .offset(x: -stripeWidth + travel * SonivoLaunchMotion.sweep(at: time))
                                            }
                                        }
                                        .accessibilityHidden(true)
                                }
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Sonivo")
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("Музыка, которую чувствуешь.")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(SN.inkMuted)
                                .multilineTextAlignment(.center)
                                .opacity(SonivoLaunchMotion.easeOut(SonivoLaunchMotion.progress(time, from: 2.05, duration: 0.35)))
                        }
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

    private func wordmark(time: Double, unit: Double, highlighted: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { index in
                let reveal = SonivoLaunchMotion.letterProgress(at: time, index: index)
                Text(SonivoLaunchMotion.brandLetters[index])
                    .font(.system(size: 62 * unit, weight: .black, design: .rounded))
                    .foregroundStyle(highlighted ? SN.accent : SN.ink)
                    .offset(y: reduceMotion ? 0 : (1 - reveal) * 22 * unit)
                    .opacity(reveal)
            }
        }
    }

    private func soundMark(time: Double, unit: Double) -> some View {
        let accent = reduceMotion ? 0 : SonivoLaunchMotion.accentVisibility(at: time)
        let impact = reduceMotion ? 0 : SonivoLaunchMotion.impact(at: time)
        return ZStack {
            RadialGradient(colors: [SN.accent.opacity(0.18 + impact * 0.12), SN.ember.opacity(0.06), .clear],
                           center: .center, startRadius: 4, endRadius: 138 * unit)
                .frame(width: 280 * unit, height: 280 * unit)
                .scaleEffect(reduceMotion ? 1 : 0.96 + impact * 0.08)
                .opacity(SonivoLaunchMotion.markProgress(at: time, index: 2))
            Circle()
                .stroke(SN.accent.opacity(accent * 0.32), lineWidth: 1.5)
                .frame(width: 108 * unit, height: 108 * unit)
                .scaleEffect(reduceMotion ? 1 : 0.94 + SonivoLaunchMotion.progress(time, from: SonivoLaunchMotion.hapticOnsets[0], duration: 0.64) * 0.32)
            ForEach(0..<5, id: \.self) { index in
                let reveal = SonivoLaunchMotion.markProgress(at: time, index: index)
                let drift = Double(index - 2) * 25 * (1 - reveal)
                Capsule()
                    .fill(LinearGradient(colors: [SN.accent, SN.ember], startPoint: .top, endPoint: .bottom))
                    .frame(width: 11 * unit, height: SonivoLaunchMotion.markHeights[index] * unit)
                    .overlay(Capsule().strokeBorder(SN.ink.opacity(0.16), lineWidth: 0.75))
                    .scaleEffect(y: reduceMotion ? 1 : 0.92 + reveal * 0.08 + impact * 0.055)
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
            let events = zip(SonivoLaunchMotion.hapticOnsets, SonivoLaunchMotion.hapticStrengths).flatMap { onset, strength -> [CHHapticEvent] in
                let impact = CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
                ], relativeTime: onset)
                let body = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: strength * 0.40),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)
                ], relativeTime: onset + 0.02, duration: SonivoLaunchMotion.hapticBodyDuration)
                return [impact, body]
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
