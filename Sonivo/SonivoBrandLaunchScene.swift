import SwiftUI

/// Native vector version of the approved preview. No video player, network or sensors.
struct SonivoBrandLaunchScene: View {
    let time: Double
    let reduceMotion: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, 600)
            ZStack {
                Color(red: 15.0 / 255, green: 15.0 / 255, blue: 18.0 / 255)
                SonivoBrandLaunchMark(time: time, reduceMotion: reduceMotion)
                    .frame(width: width, height: width)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.44)
                SonivoLaunchNameShape()
                    .fill(Color.white.opacity(0.94))
                    .aspectRatio(SonivoLaunchNameShape.aspect, contentMode: .fit)
                    .frame(width: width * 0.356)
                    .opacity(reduceMotion ? 1 : SonivoBrandLaunchMotion.name(time))
                    .offset(y: reduceMotion ? 0 : 12 * (1 - SonivoBrandLaunchMotion.name(time)))
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.598)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Музыка, которую чувствуешь.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.58))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .opacity(reduceMotion ? 1 : SonivoBrandLaunchMotion.tagline(time))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.654)
                }
            }
            .opacity(reduceMotion ? 1 : SonivoBrandLaunchMotion.opacity(time))
        }
        .accessibilityLabel("Sonivo")
        .accessibilityIdentifier("sonivo.launch.intro")
    }
}

private struct SonivoBrandLaunchMark: View {
    let time: Double
    let reduceMotion: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    private let centers: [CGFloat] = [548.4, 582, 615.6, 649.2, 682.8]
    private let heights: [CGFloat] = [50.4, 92.4, 142.8, 92.4, 50.4]
    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / 1024
            let signature = reduceMotion ? 1 : SonivoBrandLaunchMotion.signature(time)
            ZStack(alignment: .topLeading) {
                SonivoLaunchSignatureShape().fill(.white)
                    .opacity(signature)
                    .scaleEffect(1 + 0.055 * (1 - signature))
                    .offset(x: -13 * (1 - signature) * unit)
                SonivoLaunchSoundContour()
                    .trim(from: 0, to: reduceMotion ? 1 : SonivoBrandLaunchMotion.contour(time))
                    .stroke(.white, style: StrokeStyle(lineWidth: 16.8 * unit, lineCap: .round, lineJoin: .round))
                ForEach(0..<5) { index in
                    let amount = reduceMotion ? 1 : SonivoBrandLaunchMotion.bar(time, index: index)
                    let pulse = reduceMotion ? 1 : SonivoBrandLaunchMotion.pulse(time)
                    Capsule()
                        .fill(contrast == .increased ? Color.white : SN.accent)
                        .frame(width: 19.6 * unit, height: heights[index] * unit * (0.08 + 0.92 * amount) * pulse)
                        .opacity(amount)
                        .position(x: centers[index] * unit, y: 512 * unit)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Original contour's centerline, stroked with its original 16.8-unit width.
private nonisolated struct SonivoLaunchSoundContour: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 458.8, y: 358))
        p.addLine(to: CGPoint(x: 738.8, y: 358))
        p.addCurve(to: CGPoint(x: 892.8, y: 512),
                   control1: CGPoint(x: 823.8518, y: 358), control2: CGPoint(x: 892.8, y: 426.9482))
        p.addCurve(to: CGPoint(x: 738.8, y: 666),
                   control1: CGPoint(x: 892.8, y: 597.0518), control2: CGPoint(x: 823.8518, y: 666))
        p.addLine(to: CGPoint(x: 458.8, y: 666))
        return p.applying(CGAffineTransform(scaleX: rect.width / 1024, y: rect.height / 1024))
    }
}
