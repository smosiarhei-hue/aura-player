import SwiftUI
import UIKit

/// Full-screen liquid sweep for “Shake the Wave”. The crest travels vertically across
/// the display and uses the accent selected in Settings.
struct WaveShakeOverlayView: View {
    let isActive: Bool
    let triggerCount: Int
    let palette: [Color]
    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStartTime: TimeInterval = 0
    @State private var hudVisible = false
    @State private var dismissalTask: Task<Void, Never>?

    private let sweepDuration: TimeInterval = 1.65
    private var primary: Color { palette.first ?? SN.accent }
    private var secondary: Color { palette.dropFirst().first ?? SN.flame }

    var body: some View {
        ZStack(alignment: .top) {
            if isActive {
                if reduceMotion { reducedMotionWash } else { liquidSweep }
                if hudVisible {
                    statusPill
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if isActive { startWaveAnimation() } }
        .onChange(of: triggerCount) { _, _ in if isActive { startWaveAnimation() } }
        .onChange(of: isActive) { _, active in
            if active { startWaveAnimation() } else { dismissalTask?.cancel() }
        }
        .onDisappear { dismissalTask?.cancel() }
    }

    private var liquidSweep: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !isActive)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let elapsed = max(0, timeline.date.timeIntervalSinceReferenceDate - animationStartTime)
                let rawProgress = min(1, elapsed / sweepDuration)
                let progress = fluidProgress(rawProgress)
                let fade = fadeEnvelope(rawProgress)

                // Enters below the display and rises past the Dynamic Island.
                let yCrest = size.height * 1.16 - progress * size.height * 1.38
                drawAtmosphere(in: &context, size: size, progress: progress, opacity: fade)
                drawBackwash(in: &context, size: size, yCrest: yCrest, time: elapsed, opacity: fade)
                drawLiquidBody(in: &context, size: size, yCrest: yCrest, time: elapsed, opacity: fade)
                drawCausticCrest(in: &context, size: size, yCrest: yCrest, time: elapsed, opacity: fade)
                drawDroplets(in: &context, size: size, yCrest: yCrest, progress: progress, opacity: fade)
            }
            .drawingGroup(opaque: false, colorMode: .linear)
        }
    }

    private var reducedMotionWash: some View {
        LinearGradient(
            colors: [primary.opacity(0.42), secondary.opacity(0.24), Color.black.opacity(0.08)],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
        .transition(.opacity)
    }

    private var statusPill: some View {
        HStack(spacing: 11) {
            Image(systemName: "water.waves")
                .font(.system(.body, design: .rounded, weight: .bold))
                .foregroundStyle(primary)
                .frame(width: 34, height: 34)
                .background(primary.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(SN.text(.subheadline, .bold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(SN.text(.caption2)).foregroundStyle(.white.opacity(0.66)).lineLimit(1)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [primary.opacity(0.72), Color.white.opacity(0.14)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 0.8
            )
        }
        .shadow(color: primary.opacity(0.26), radius: 18, y: 8)
    }

    private func drawAtmosphere(
        in context: inout GraphicsContext,
        size: CGSize,
        progress: Double,
        opacity: Double
    ) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: secondary.opacity(0.04 * opacity), location: 0),
                    .init(color: primary.opacity(0.18 * opacity), location: max(0.1, 1 - progress)),
                    .init(color: Color.black.opacity(0.03 * opacity), location: 1)
                ]),
                startPoint: CGPoint(x: size.width * 0.15, y: size.height),
                endPoint: CGPoint(x: size.width * 0.85, y: 0)
            )
        )
    }

    private func drawBackwash(
        in context: inout GraphicsContext,
        size: CGSize,
        yCrest: CGFloat,
        time: TimeInterval,
        opacity: Double
    ) {
        let path = liquidPath(size: size, yCrest: yCrest + 52, amplitude: 26, wavelength: 1.55, phase: time * 2.4)
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    secondary.opacity(0.04 * opacity),
                    secondary.opacity(0.25 * opacity),
                    primary.opacity(0.08 * opacity)
                ]),
                startPoint: CGPoint(x: size.width * 0.5, y: yCrest - 20),
                endPoint: CGPoint(x: size.width * 0.5, y: size.height)
            )
        )
    }

    private func drawLiquidBody(
        in context: inout GraphicsContext,
        size: CGSize,
        yCrest: CGFloat,
        time: TimeInterval,
        opacity: Double
    ) {
        let path = liquidPath(size: size, yCrest: yCrest, amplitude: 42, wavelength: 1.22, phase: time * 3.1)
        context.fill(
            path,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(0.10 * opacity), location: 0),
                    .init(color: primary.opacity(0.52 * opacity), location: 0.08),
                    .init(color: primary.opacity(0.24 * opacity), location: 0.42),
                    .init(color: secondary.opacity(0.14 * opacity), location: 1)
                ]),
                startPoint: CGPoint(x: size.width * 0.5, y: yCrest - 28),
                endPoint: CGPoint(x: size.width * 0.5, y: size.height)
            )
        )
    }

    private func drawCausticCrest(
        in context: inout GraphicsContext,
        size: CGSize,
        yCrest: CGFloat,
        time: TimeInterval,
        opacity: Double
    ) {
        let crest = crestPath(width: size.width, yCrest: yCrest, amplitude: 42, wavelength: 1.22, phase: time * 3.1)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 12))
            glow.stroke(
                crest,
                with: .color(primary.opacity(0.72 * opacity)),
                style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round)
            )
        }
        context.stroke(
            crest,
            with: .linearGradient(
                Gradient(colors: [
                    primary.opacity(0.78 * opacity),
                    Color.white.opacity(0.96 * opacity),
                    secondary.opacity(0.82 * opacity)
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ),
            style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawDroplets(
        in context: inout GraphicsContext,
        size: CGSize,
        yCrest: CGFloat,
        progress: Double,
        opacity: Double
    ) {
        guard progress > 0.08 && progress < 0.92 else { return }
        for index in 0..<18 {
            let seed = Double(index)
            let x = CGFloat((seed * 83.17).truncatingRemainder(dividingBy: Double(size.width)))
            let lift = CGFloat(16 + (seed * 19).truncatingRemainder(dividingBy: 72))
            let radius = CGFloat(1.5 + (seed * 0.73).truncatingRemainder(dividingBy: 3.4))
            let waveOffset = sin((x / max(1, size.width)) * .pi * 2.4 + seed) * 18
            let rect = CGRect(x: x - radius, y: yCrest - lift + waveOffset - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity((0.22 + seed.truncatingRemainder(dividingBy: 3) * 0.08) * opacity))
            )
        }
    }

    private func liquidPath(
        size: CGSize,
        yCrest: CGFloat,
        amplitude: CGFloat,
        wavelength: CGFloat,
        phase: Double
    ) -> Path {
        var path = crestPath(width: size.width, yCrest: yCrest, amplitude: amplitude, wavelength: wavelength, phase: phase)
        path.addLine(to: CGPoint(x: size.width, y: size.height + 2))
        path.addLine(to: CGPoint(x: 0, y: size.height + 2))
        path.closeSubpath()
        return path
    }

    private func crestPath(
        width: CGFloat,
        yCrest: CGFloat,
        amplitude: CGFloat,
        wavelength: CGFloat,
        phase: Double
    ) -> Path {
        var path = Path()
        let step = max(2, width / 150)
        var x: CGFloat = 0
        path.move(to: CGPoint(x: 0, y: waveY(x: 0, width: width, yCrest: yCrest, amplitude: amplitude, wavelength: wavelength, phase: phase)))
        while x <= width {
            path.addLine(to: CGPoint(x: x, y: waveY(x: x, width: width, yCrest: yCrest, amplitude: amplitude, wavelength: wavelength, phase: phase)))
            x += step
        }
        return path
    }

    private func waveY(
        x: CGFloat,
        width: CGFloat,
        yCrest: CGFloat,
        amplitude: CGFloat,
        wavelength: CGFloat,
        phase: Double
    ) -> CGFloat {
        let normalizedX = x / max(1, width)
        let primaryWave = sin(normalizedX * .pi * 2 * wavelength + phase) * amplitude
        let detailWave = sin(normalizedX * .pi * 5.2 - phase * 0.68) * amplitude * 0.23
        return yCrest + primaryWave + detailWave
    }

    private func fluidProgress(_ value: Double) -> Double {
        let clamped = max(0, min(1, value))
        return 1 - pow(1 - clamped, 3.2)
    }

    private func fadeEnvelope(_ value: Double) -> Double {
        if value < 0.08 { return value / 0.08 }
        if value > 0.80 { return max(0, (1 - value) / 0.20) }
        return 1
    }

    private func startWaveAnimation() {
        dismissalTask?.cancel()
        animationStartTime = Date().timeIntervalSinceReferenceDate
        withAnimation(SN.fastSpring) { hudVisible = true }

        dismissalTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 700_000_000 : 1_420_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { hudVisible = false }
            try? await Task.sleep(nanoseconds: reduceMotion ? 180_000_000 : 420_000_000)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
