import SwiftUI

/// A stationary EDR/HDR flash around the committed artwork. The pulse is fed
/// only by sub-bass energy and kick transients from the main audio mixer.
struct MusicReactiveLiquidBorder: View {
    let player: ActivePlayerPresentation
    let cornerRadius: CGFloat
    let palette: [Color]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spectrum = SpectrumAnalyzer.shared

    var body: some View {
        let bass = player.isPlaying ? CGFloat(spectrum.bass) : 0
        let kick = player.isPlaying && !reduceMotion ? CGFloat(spectrum.kick) : 0
        let pulse = min(1, max(kick, bass * 0.42))
        let accent = palette.first ?? .cyan

        // Apple renders this offscreen group in the extended-linear working
        // color space. exposureAdjust/headroom preserve EDR values above SDR
        // white on supported displays; plusLighter layers provide the bloom.
        let hdrWhite = Color.white.exposureAdjust(2.15).headroom(4.0)
        let hdrAccent = accent.exposureAdjust(1.35).headroom(2.5)

        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(player.isPlaying ? 0.18 : 0.08), lineWidth: 0.8)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrAccent.opacity(0.16 + Double(pulse) * 0.42),
                              lineWidth: 2.0 + pulse * 4.5)
                .blur(radius: 13 + pulse * 24)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrWhite.opacity(0.20 + Double(pulse) * 0.78),
                              lineWidth: 1.0 + pulse * 2.7)
                .blur(radius: 4 + pulse * 9)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(hdrWhite.opacity(0.34 + Double(pulse) * 0.66),
                              lineWidth: 0.8 + pulse * 1.6)
        }
        .padding(2)
        .scaleEffect(1 + pulse * 0.012)
        .shadow(color: hdrAccent.opacity(Double(pulse) * 0.72), radius: 8 + pulse * 25)
        .compositingGroup()
        .blendMode(.plusLighter)
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .id(player.displayTrack?.id)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
