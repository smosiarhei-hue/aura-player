import SwiftUI

// MARK: - Blob position helper

private func blobGeometry(index: Int, t: Double, w: Double, h: Double) -> (cx: Double, cy: Double, radius: Double) {
    let fi = Double(index)
    let speed = 0.12 + 0.05 * (fi.truncatingRemainder(dividingBy: 3))
    let phase = fi * 1.047 + t * speed
    let cx = w * (0.5 + 0.34 * sin(phase + fi * 0.7))
    let cy = h * (0.5 + 0.32 * cos(phase * 0.83 + fi * 1.3))
    let r = min(w, h) * (0.22 + 0.06 * sin(t * 0.6 + fi * 2.1))
    return (cx, cy, r)
}

// MARK: - Animated artwork (видеошот-подобная анимация)

struct AnimatedArtworkView: View {
    let palette: [Color]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let w = Double(size.width)
                let h = Double(size.height)
                for i in 0..<6 {
                    let geo = blobGeometry(index: i, t: t, w: w, h: h)
                    let color = palette[i % max(palette.count, 1)]
                    let rect = CGRect(x: geo.cx - geo.radius, y: geo.cy - geo.radius,
                                      width: geo.radius * 2, height: geo.radius * 2)
                    ctx.opacity = 0.8
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.22), .clear, .black.opacity(0.30)], startPoint: .top, endPoint: .bottom))
        .clipped()
    }
}

// MARK: - Static small artwork thumbnail

struct SmallArtwork: View {
    let palette: [Color]
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// MARK: - Spectrum bars

struct SpectrumView: View {
    @StateObject private var analyzer = SpectrumAnalyzer.shared
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: max(2, (geo.size.width - CGFloat(SpectrumAnalyzer.bandCount) * barWidth) / CGFloat(max(SpectrumAnalyzer.bandCount - 1, 1)))) {
                ForEach(0..<SpectrumAnalyzer.bandCount, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(
                            colors: [SettingsStore.shared.accentColor, SettingsStore.shared.accent.colors.last ?? .teal],
                            startPoint: .bottom, endPoint: .top
                        ))
                        .frame(width: barWidth, height: max(3, CGFloat(analyzer.bands[i]) * maxHeight))
                }
            }
            .frame(width: geo.size.width, height: maxHeight, alignment: .bottom)
        }
        .frame(height: maxHeight)
    }
}
