import SwiftUI

/// Two native light layers, not a full-screen ray marcher or a second render clock.
struct SonivoLaunchAtmosphere: View {
    let time: Double
    let reduced: Bool
    let increasedContrast: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let drift = reduced ? 0 : SonivoLaunchMotion.atmosphereDrift(at: time)
            let light = colorScheme == .light
            ZStack {
                RadialGradient(
                    colors: [SN.accent.opacity(light ? 0.10 : 0.21), .clear],
                    center: UnitPoint(x: 0.20, y: 0.48),
                    startRadius: 0, endRadius: geometry.size.width * 0.85
                )
                .offset(x: geometry.size.width * drift, y: geometry.size.height * drift * 0.24)
                RadialGradient(
                    colors: [SN.ink.opacity(light ? 0.05 : 0.09), .clear],
                    center: UnitPoint(x: 0.82, y: 0.36),
                    startRadius: 0, endRadius: geometry.size.width * 0.70
                )
                .offset(x: -geometry.size.width * drift * 0.65)
            }
            .opacity(increasedContrast || reduceTransparency ? 0 : 1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}