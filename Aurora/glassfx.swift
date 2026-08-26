import SwiftUI

// MARK: - Liquid Glass Motion System
// Пружинные нажатия, бегущий блик по стеклу, дышащее свечение и
// появление секций с мягким сдвигом — современные анимации в духе Liquid Glass.
// Совместимо с iOS 16+.

/// Кнопка, которая «прилипает» к пальцу: пружинное сжатие без резких рывков.
struct GlassPressStyle: ButtonStyle {
    var scale: CGFloat = 0.965

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(AG.fastSpring, value: configuration.isPressed)
    }
}

/// Бегущий блик по поверхности стеклянной карточки.
struct ShimmerOverlay: View {
    var corner: CGFloat = 24
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: geo.size.width * 0.45)
                .rotationEffect(.degrees(18))
                .offset(x: -geo.size.width * 0.6 + phase * geo.size.width * 2.4)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// Дышащее янтарное свечение вокруг карточки.
struct PulsingGlow: ViewModifier {
    var color: Color = AG.ember
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(pulse ? 0.50 : 0.22), radius: pulse ? 26 : 12, y: 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

extension View {
    func pulsingGlow(_ color: Color = AG.ember) -> some View {
        modifier(PulsingGlow(color: color))
    }
}

/// Появление секции с лёгким сдвигом вверх — как карточки в современных iOS-экранах.
struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 18)
            .onAppear {
                withAnimation(AG.spring.delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0) -> some View {
        modifier(RiseIn(delay: delay))
    }
}
