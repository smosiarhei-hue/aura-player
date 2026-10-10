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

/// Anchors track the actual native text bounds rather than estimated glyph widths.
nonisolated private struct SonivoLaunchFocusBounds: PreferenceKey {
    static var defaultValue: [Int: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SonivoLaunchIntro: View {
    let epoch: TimeInterval
    let reduceMotion: Bool
    let onSkip: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredWordWidth: Double?
    @State private var measuredGroupHeight: Double?

    var body: some View {
        GeometryReader { geometry in
            let unit = Double(min(1.3, min(geometry.size.width / 390, geometry.size.height / 844)))
            // Include the focus corners in fitting, so the oversized opening is never cropped.
            let wordWidth = (measuredWordWidth ?? 225 * unit) + SonivoLaunchMotion.focusPadding * 2
            let groupHeight = (measuredGroupHeight ?? 118 * unit) + SonivoLaunchMotion.focusPadding * 2
            let peak = max(1, min(2.2, min((Double(geometry.size.width) - 32) / wordWidth,
                                          max(1, Double(geometry.size.height) - 140) / groupHeight)))
            TimelineView(.animation(paused: reduceMotion || scenePhase != .active)) { _ in
                let time = reduceMotion ? SonivoLaunchMotion.reducedPreviewTime
                    : (epoch > 0 ? max(0, CACurrentMediaTime() - epoch) : 0)
                ZStack {
                    SN.bg.ignoresSafeArea()
                    RadialGradient(colors: [SN.accent.opacity(0.08), .clear], center: .center,
                                   startRadius: 0, endRadius: min(geometry.size.width, geometry.size.height) * 0.60)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    focusScene(time: time, unit: unit)
                        .scaleEffect(reduceMotion ? 1 : SonivoLaunchMotion.zoom(at: time, peak: peak))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -24 * unit)
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
                .opacity(reduceMotion ? 1 : SonivoLaunchMotion.opacity(at: time))
            }
        }
        .accessibilityIdentifier("sonivo.launch.intro")
    }

    private func focusScene(time: Double, unit: Double) -> some View {
        VStack(spacing: 22 * unit) {
            focusedWord("Sonivo", index: 0, time: time, fontSize: 62 * unit)
                .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { measuredWordWidth = $0 }
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 10 * unit) {
                    focusedWord("Твоя", index: 1, time: time, fontSize: 24 * unit)
                    focusedWord("музыка", index: 2, time: time, fontSize: 24 * unit)
                }
                .opacity(reduceMotion ? 1 : SonivoLaunchMotion.easeOut(SonivoLaunchMotion.progress(time, from: 1.04, duration: 0.24)))
                .accessibilityHidden(true)
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { measuredGroupHeight = $0 }
        .overlayPreferenceValue(SonivoLaunchFocusBounds.self) { anchors in
            GeometryReader { resolver in
                if !reduceMotion, let brandAnchor = anchors[0] {
                    let brand = resolver[brandAnchor]
                    let first = anchors[1].map { resolver[$0] } ?? brand
                    let second = anchors[2].map { resolver[$0] } ?? brand
                    let weights = dynamicTypeSize.isAccessibilitySize
                        ? SonivoLaunchFocusWeights(brand: 1, first: 0, second: 0)
                        : SonivoLaunchMotion.focusWeights(at: time)
                    let bounds = blend(brand, first, second, weights: weights)
                        .insetBy(dx: -SonivoLaunchMotion.focusPadding, dy: -6)
                    cornerPath(in: bounds)
                        .stroke(SN.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .shadow(color: SN.accent.opacity(0.35 + SonivoLaunchMotion.impact(at: time) * 0.20), radius: 4)
                        .opacity(SonivoLaunchMotion.easeOut(SonivoLaunchMotion.progress(time, from: 0.12, duration: 0.20)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sonivo")
    }

    private func focusedWord(_ text: String, index: Int, time: Double, fontSize: Double) -> some View {
        let blur = reduceMotion || dynamicTypeSize.isAccessibilitySize ? 0 : SonivoLaunchMotion.blur(at: time, index: index)
        return Text(text)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(SN.ink)
            .fixedSize()
            .blur(radius: blur)
            .anchorPreference(key: SonivoLaunchFocusBounds.self, value: .bounds) { [index: $0] }
            .opacity(reduceMotion ? 1 : SonivoLaunchMotion.easeOut(SonivoLaunchMotion.progress(time, from: 0.08, duration: 0.22)))
    }

    private func blend(_ a: CGRect, _ b: CGRect, _ c: CGRect, weights: SonivoLaunchFocusWeights) -> CGRect {
        let wa = CGFloat(weights.brand), wb = CGFloat(weights.first), wc = CGFloat(weights.second)
        return CGRect(x: a.minX * wa + b.minX * wb + c.minX * wc,
                      y: a.minY * wa + b.minY * wb + c.minY * wc,
                      width: a.width * wa + b.width * wb + c.width * wc,
                      height: a.height * wa + b.height * wb + c.height * wc)
    }
    private func cornerPath(in rect: CGRect) -> Path {
        let length = min(16, min(rect.width, rect.height) * 0.30)
        return Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
            p.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY - length))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + length, y: rect.maxY))
            p.move(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
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
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: strength * 0.55),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)
                ], relativeTime: onset + 0.02, duration: SonivoLaunchMotion.hapticBodyDuration)
                return [impact, body]
            }
            let zoomTicks = zip(SonivoLaunchMotion.zoomTickOnsets, SonivoLaunchMotion.zoomTickStrengths).map { onset, strength in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: strength),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.16)
                ], relativeTime: onset)
            }
            let pattern = try CHHapticPattern(events: events + zoomTicks, parameters: [])
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
