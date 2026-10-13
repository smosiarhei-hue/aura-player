import SwiftUI

/// Uppercase branding stays a single intact word, not six independently flying letters.
struct SonivoLaunchWordmark: View {
    let time: Double
    let width: CGFloat
    let unit: CGFloat
    let brandFontName: String?
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let height = 82 * unit
        Text("SONIVO")
            .font(brandFontName.map { Font.custom($0, fixedSize: 65 * unit) }
                  ?? .system(size: 65 * unit, weight: .regular, design: .serif))
            .foregroundStyle(Color(red: 0.95, green: 0.93, blue: 0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: width, height: height)
            .layerEffect(ShaderLibrary.sonivoLaunchRadialExposure(
                .float2(Float(width), Float(height)), .float(Float(time)), .float(1)),
                maxSampleOffset: CGSize(width: width * 0.25, height: height * 0.25),
                isEnabled: !reduceMotion && time < 1.95)
            .colorEffect(ShaderLibrary.sonivoLaunchWordHighlight(
                .float2(Float(width), Float(height)), .float(Float(time))),
                isEnabled: !reduceMotion && !reduceTransparency && contrast != .increased)
            .scaleEffect(reduceMotion ? 1 : SonivoLaunchMotion.wordScale(at: time))
            .opacity(reduceMotion ? 1 : SonivoLaunchMotion.wordOpacity(at: time))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
