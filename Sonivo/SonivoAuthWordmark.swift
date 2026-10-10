import SwiftUI

/// The approved offline brand face and the existing bounded SDR chrome shader.
struct SonivoAuthWordmark: View {
    var size: CGFloat = 42
    var animates = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var fontName: String?
    @State private var surfaceTime: Float = 0
    var body: some View {
        let time = surfaceTime
        let light = scheme == .light
        let enabled = animates && !reduceMotion && contrast != .increased
        Text("Sonivo")
            .font(fontName.map { .custom($0, size: size, relativeTo: .largeTitle) } ?? .system(.largeTitle, weight: .heavy))
            .foregroundStyle(.primary)
            .lineLimit(1).minimumScaleFactor(0.65)
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.sonivoLaunchChrome(
                    .float2(Float(proxy.size.width), Float(proxy.size.height)), .float(time), .float(light ? 1 : 0)), isEnabled: enabled)
            }
            .accessibilityLabel("Sonivo")
            .task {
                fontName = SonivoLaunchTypography.prepare()
                guard enabled else { return }
                withAnimation(.linear(duration: 4.2)) { surfaceTime = 4.2 }
            }
    }
}
