import SwiftUI

/// Stationary artwork-colour EDR bloom driven only by kick and 30...120 Hz bass.
struct MusicReactiveLiquidBorder: View {
    let player: ActivePlayerPresentation
    let cornerRadius: CGFloat
    let palette: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spectrum = SpectrumAnalyzer.shared

    var body: some View {
        let bass = player.isPlaying ? CGFloat(spectrum.bass) : 0
        let kick = player.isPlaying && !reduceMotion ? CGFloat(spectrum.kick) : 0
        let pulse = min(1, max(kick, bass * 0.62))
        let primary = palette.first ?? .cyan
        let secondary = palette.dropFirst().first ?? primary
        let tertiary = palette.dropFirst(2).first ?? secondary
        let hdrPrimary = primary.exposureAdjust(2.35).headroom(5.0)
        let hdrSecondary = secondary.exposureAdjust(1.95).headroom(4.0)
        let hdrTertiary = tertiary.exposureAdjust(1.55).headroom(3.2)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(primary.opacity(player.isPlaying ? 0.22 : 0.08), lineWidth: 0.8)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrTertiary.opacity(0.10 + Double(pulse) * 0.50),
                              lineWidth: 4 + pulse * 8)
                .blur(radius: 24 + pulse * 34)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrSecondary.opacity(0.15 + Double(pulse) * 0.68),
                              lineWidth: 2.5 + pulse * 6)
                .blur(radius: 12 + pulse * 22)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrPrimary.opacity(0.28 + Double(pulse) * 0.72),
                              lineWidth: 1.2 + pulse * 3.8)
                .blur(radius: 3 + pulse * 9)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrPrimary.opacity(0.42 + Double(pulse) * 0.58),
                              lineWidth: 0.9 + pulse * 2.1)
        }
        .padding(2)
        .scaleEffect(1 + pulse * 0.018)
        .shadow(color: hdrPrimary.opacity(Double(pulse) * 0.86), radius: 10 + pulse * 34)
        .compositingGroup()
        .blendMode(.plusLighter)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .animation(.linear(duration: 0.045), value: pulse)
        .id(player.displayTrack?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
