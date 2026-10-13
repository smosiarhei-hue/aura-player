import SwiftUI

/// Bundled generated material, decoded by the asset system, not a played video.
/// One finite temporal shader smears the actual scale trajectory, then becomes inactive.
struct SonivoResonanceSymbol: View {
    let time: Double
    let size: CGFloat
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var enhancedMaterial: Bool { !reduceMotion && !reduceTransparency && contrast != .increased }
    private var logo: some View {
        Image("ResonanceLaunchLogo").resizable().scaledToFit()
            .frame(width: size, height: size)
    }
    var body: some View {
        ZStack {
            logo
                .layerEffect(ShaderLibrary.sonivoLaunchRadialExposure(
                    .float2(Float(size), Float(size)), .float(Float(time)), .float(0)),
                    maxSampleOffset: CGSize(width: size * 0.25, height: size * 0.25),
                    isEnabled: !reduceMotion && time < 1.95)
            if enhancedMaterial {
                logo.blendMode(.screen).opacity(SonivoLaunchMotion.fixationFlash(at: time))
                Ellipse()
                    .stroke(Color(red: 1, green: 0.69, blue: 0.55), lineWidth: 1.3)
                    .frame(width: size * 0.616, height: size * 0.672)
                    .rotationEffect(.radians(-0.13))
                    .scaleEffect(1 + 0.30 * SonivoLaunchMotion.waveProgress(at: time))
                    .shadow(color: Color(red: 1, green: 0.59, blue: 0.42), radius: 9)
                    .opacity(SonivoLaunchMotion.waveOpacity(at: time))
            }
        }
        .frame(width: size, height: size)
        .opacity(reduceMotion ? 1 : SonivoLaunchMotion.ringOpacity(at: time))
        .scaleEffect(reduceMotion ? 1 : SonivoLaunchMotion.ringScale(at: time))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
