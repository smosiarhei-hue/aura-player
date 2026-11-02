import SwiftUI

/// Automix label on the player timeline — Lab choreography, native white HDR shimmer.
/// Soft EDR shine when the display has headroom; stays readable as plain text otherwise.
struct AIDJTransitionBadgeView: View {
    let incomingTrack: Track?
    var phaseLabel: String?

    init(incomingTrack: Track? = nil, phaseLabel: String? = nil) {
        self.incomingTrack = incomingTrack
        self.phaseLabel = phaseLabel
    }

    @State private var l10n = SonivoL10n.shared
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var title: String {
        let raw = phaseLabel ?? ""
        if raw.hasPrefix("DUET") || raw.contains("DUET") { return l10n.duet }
        if AutoMixDJEngine.shared.activeStrategyName == "DUET" { return l10n.duet }
        return l10n.automix
    }
    private var phase: String? { l10n.automixPhase(phaseLabel) }

    var body: some View {
        VStack(spacing: 1) {
            AutomixHDRShimmerText(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let phase {
                Text(phase)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 6)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .accessibilityLabel(title)
        .accessibilityValue(phase ?? "")
        .onAppear {
            if reduceMotion || contrast == .increased {
                appeared = true
                return
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

/// White Automix word with a Lab-like shimmer sweep and native EDR headroom.
private struct AutomixHDRShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String) {
        self.text = text
    }

    private var hdrCore: Color {
        Color.white.exposureAdjust(2.4).headroom(5.2)
    }
    private var hdrSoft: Color {
        Color.white.exposureAdjust(1.6).headroom(3.4)
    }
    private var hdrPeak: Color {
        Color.white.exposureAdjust(3.1).headroom(6.0)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion || contrast == .increased ? 1.0 : 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 2.4s loop matches Lab `mixingShimmer`.
            let phase = reduceMotion || contrast == .increased
                ? 0.35
                : (t.truncatingRemainder(dividingBy: 2.4) / 2.4)
            let sweep = CGFloat(phase)
            let pulse = 0.88 + 0.12 * abs(sin(t * .pi / 1.35))

            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: hdrSoft.opacity(0.42), location: max(0, sweep - 0.28)),
                            .init(color: hdrCore, location: max(0, sweep - 0.08)),
                            .init(color: hdrPeak, location: sweep),
                            .init(color: hdrCore, location: min(1, sweep + 0.08)),
                            .init(color: hdrSoft.opacity(0.42), location: min(1, sweep + 0.28))
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .opacity(pulse)
                .shadow(color: hdrSoft.opacity(0.55), radius: 3 + 5 * pulse)
                .compositingGroup()
                .blendMode(.plusLighter)
                .drawingGroup(opaque: false, colorMode: .extendedLinear)
        }
    }
}
