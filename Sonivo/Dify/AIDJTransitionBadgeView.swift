import SwiftUI

/// Automix “Mixing” label on the player timeline — Apple Music Automix layout:
/// centered between elapsed / remaining, sitting with the progress bar row.
/// Soft EDR shine when the display has headroom; stays readable as plain text otherwise.
struct AIDJTransitionBadgeView: View {
    let incomingTrack: Track?
    var phaseLabel: String?

    init(incomingTrack: Track? = nil, phaseLabel: String? = nil) {
        self.incomingTrack = incomingTrack
        self.phaseLabel = phaseLabel
    }

    @State private var l10n = SonivoL10n.shared
    @State private var pulse = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var title: String { l10n.automix }
    private var phase: String? { l10n.automixPhase(phaseLabel) }

    private var hdrCore: Color {
        Color.white.exposureAdjust(2.4).headroom(5.2)
    }
    private var hdrSoft: Color {
        Color.white.exposureAdjust(1.6).headroom(3.4)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(hdrCore.opacity(pulse ? 1.0 : 0.88))
                .shadow(color: hdrSoft.opacity(0.55), radius: pulse ? 8 : 3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let phase {
                Text(phase)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(hdrSoft.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 6)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .compositingGroup()
        .blendMode(.plusLighter)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .accessibilityLabel(title)
        .accessibilityValue(phase ?? "")
        .onAppear {
            if reduceMotion || contrast == .increased {
                appeared = true
                pulse = true
                return
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
