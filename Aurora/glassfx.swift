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

/// Современная интерактивная пружинная анимация карточки с тактильным откликом
struct CardPressStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed && haptic {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

/// Живые анимированные столбики эквалайзера для активного трека
struct LiveWaveEqualizer: View {
    let isPlaying: Bool
    var color: Color = AG.amber
    var barCount: Int = 3

    @State private var wavePhases: [CGFloat] = [0.4, 0.9, 0.6]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 2.5, height: isPlaying ? 12 * wavePhases[i % wavePhases.count] : 3)
            }
        }
        .frame(width: 14, height: 14, alignment: .bottom)
        .onAppear {
            if isPlaying {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    wavePhases = [0.95, 0.35, 0.8]
                }
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    wavePhases = [0.95, 0.35, 0.8]
                }
            }
        }
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
