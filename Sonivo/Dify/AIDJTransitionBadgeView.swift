import SwiftUI

/// Native EDR/HDR shining “Automix / Автомикс” badge shown while a mashup
/// transition is active. Title follows `SonivoL10n`; phase is a secondary line.
struct AIDJTransitionBadgeView: View {
    let incomingTrack: Track?
    var phaseLabel: String?

    init(incomingTrack: Track? = nil, phaseLabel: String? = nil) {
        self.incomingTrack = incomingTrack
        self.phaseLabel = phaseLabel
    }

    @State private var l10n = SonivoL10n.shared
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var title: String { l10n.automix }
    private var phase: String? { l10n.automixPhase(phaseLabel) }

    /// Extended-range white for displays that support EDR headroom.
    private var hdrCore: Color {
        Color.white.exposureAdjust(2.4).headroom(5.2)
    }
    private var hdrSoft: Color {
        Color.white.exposureAdjust(1.6).headroom(3.4)
    }
    private var hdrAmber: Color {
        Color(red: 1.0, green: 0.82, blue: 0.42)
            .exposureAdjust(1.9)
            .headroom(4.0)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hdrCore)
                .shadow(color: hdrSoft.opacity(0.9), radius: pulse ? 8 : 4)
                .opacity(pulse ? 1.0 : 0.82)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [hdrCore, hdrAmber, hdrSoft],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    // Crisp glyph + HDR bloom (EDR when the display has headroom).
                    .shadow(color: hdrCore.opacity(0.95), radius: pulse ? 10 : 5)
                    .shadow(color: hdrAmber.opacity(0.55), radius: pulse ? 16 : 8)
                    .lineLimit(1)

                if let phase {
                    Text(phase)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(hdrSoft.opacity(0.78))
                        .shadow(color: hdrSoft.opacity(0.45), radius: 4)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, phase == nil ? 7 : 6)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.42))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    hdrCore.opacity(0.55),
                                    hdrAmber.opacity(0.28),
                                    hdrSoft.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: hdrCore.opacity(pulse ? 0.55 : 0.28), radius: pulse ? 14 : 7)
        }
        .compositingGroup()
        .blendMode(.plusLighter)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .accessibilityLabel(title)
        .accessibilityValue(phase ?? "")
        .onAppear {
            guard !reduceMotion, contrast != .increased else {
                pulse = true
                return
            }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
