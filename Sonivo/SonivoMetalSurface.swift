import SwiftUI
import Combine

/// Decoration only. Does not replace labels, actions, hit targets or the OS glass.
/// Only the player transport opts into a clock; all shared surfaces are static.
struct SonivoMetalSurface: ViewModifier {
    static let enabledKey = "sonivo.ui.liquidMetal.enabled"
    let cornerRadius: CGFloat
    var emphasis: Double = 0.45
    var animated: Bool = false

    @AppStorage(SonivoMetalSurface.enabledKey) private var enabled = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.displayScale) private var displayScale
    @State private var constrained = Self.isConstrained

    private static let animationEpoch = Date.timeIntervalSinceReferenceDate

    private static var isConstrained: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled || process.thermalState == .serious
            || process.thermalState == .critical
    }

    private var canRender: Bool {
        enabled && scenePhase == .active && !constrained && !reduceMotion
            && !reduceTransparency && contrast != .increased && isEnabled
    }

    func body(content: Content) -> some View {
        content.overlay {
            if canRender {
                if animated {
                    // No paused-but-ticking clock: this entire subtree is removed
                    // when inactive, constrained, disabled or accessibility asks.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        ring(time: Float(context.date.timeIntervalSinceReferenceDate
                            - Self.animationEpoch) * 0.20)
                    }
                } else {
                    ring(time: 1.6)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            constrained = Self.isConstrained
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            constrained = Self.isConstrained
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { constrained = Self.isConstrained }
        }
    }

    private func ring(time: Float) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(.white, lineWidth: animated ? 2.5 : 1.25)
            .colorEffect(ShaderLibrary.sonivoLiquidMetal(
                .boundingRect, .float(time),
                .color(.clear), .color(SN.accent.opacity(colorScheme == .dark ? 0.24 : 0.16)),
                .float(1.5), .float(0.09), .float(0.30), .float(0.30),
                .float(0.10), .float(0.40), .float(90),
                .float(Float(emphasis)), .float(Float(displayScale))
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A restrained specular rim, not a metallic text replacement.
    func sonivoMetal(corner: CGFloat, emphasis: Double = 0.45, animated: Bool = false) -> some View {
        modifier(SonivoMetalSurface(cornerRadius: corner, emphasis: emphasis, animated: animated))
    }
}
