import SwiftUI

/// Three precise, rounded faders. Visual-only; no EQ or audio mutation.
struct SonivoEqualizerGlyph: View {
    var size: CGFloat = 24
    var body: some View {
        Canvas { context, bounds in
            let unit = min(bounds.width, bounds.height) / 24
            for (index, knob) in [15.0, 7, 18].enumerated() {
                let x = (4 + CGFloat(index) * 8) * unit
                var rail = Path()
                rail.move(to: CGPoint(x: x, y: 2 * unit))
                rail.addLine(to: CGPoint(x: x, y: 22 * unit))
                context.stroke(rail, with: .foreground, style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round))
                let circle = CGRect(x: x - 3 * unit, y: CGFloat(knob) * unit - 3 * unit, width: 6 * unit, height: 6 * unit)
                context.fill(Path(ellipseIn: circle), with: .foreground)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
