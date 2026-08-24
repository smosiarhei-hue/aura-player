import SwiftUI

// MARK: - Animated artwork (видеошот-подобная анимация)

struct AnimatedArtworkView: View {
    let palette: [Color]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let w = Double(size.width)
                let h = Double(size.height)
                let count = max(palette.count, 1)
                for i in 0..<6 {
                    let fi = Double(i)
                    let speed: Double = 0.12 + 0.05 * (fi.truncatingRemainder(dividingBy: 3))
                    let phase: Double = fi * 1.047 + t * speed
                    let wave1: Double = sin(phase + fi * 0.7)
                    let wave2: Double = cos(phase * 0.83 + fi * 1.3)
                    let wave3: Double = sin(t * 0.6 + fi * 2.1)
                    let cx: Double = w * (0.5 + 0.34 * wave1)
                    let cy: Double = h * (0.5 + 0.32 * wave2)
                    let radius: Double = min(w, h) * (0.22 + 0.06 * wave3)
                    let color = palette[i % count].opacity(0.85)
                    let center = CGPoint(x: cx, y: cy)
                    let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                    let grad = GraphicsContext.RadialGradient(color: color, center: center, startRadius: 0, endRadius: radius)
                    ctx.fill(Path(ellipseIn: rect), with: .radialGradient(grad, center: center, startRadius: 0, endRadius: radius))
                }
            }
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.22), .clear, .black.opacity(0.30)], startPoint: .top, endPoint: .bottom))
        .clipped()
    }
}

// MARK: - Static small artwork thumbnail

struct SmallArtwork: View {
    script placeholder
}
