import SwiftUI

/// The approved asymmetric silhouette is a bundled alpha mask, decoded by the asset system.
/// Color and a single passing highlight are native gradients; no video or font decoding per frame.
struct SonivoResonanceSymbol: View {
    let time: Double
    let theme: AppThemeColor
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.swatchColor, theme.swatchColor,
                                    theme.swatchColor.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
            if !reduceMotion, !reduceTransparency, contrast != .increased {
                AngularGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.42),
                    .init(color: .white.opacity(0.78), location: 0.49),
                    .init(color: .clear, location: 0.57),
                    .init(color: .clear, location: 1)
                ], center: .center,
                   angle: .degrees(-130 + 240 * SonivoLaunchMotion.lightProgress(at: time)))
                .opacity(SonivoLaunchMotion.lightOpacity(at: time))
            }
        }
        .mask {
            Image("ResonanceRingMask").resizable().scaledToFit()
        }
        .opacity(reduceMotion ? 1 : SonivoLaunchMotion.ringOpacity(at: time))
        .scaleEffect(reduceMotion ? 1 : SonivoLaunchMotion.ringScale(at: time))
        .blur(radius: reduceMotion ? 0 : SonivoLaunchMotion.ringBlur(at: time))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
