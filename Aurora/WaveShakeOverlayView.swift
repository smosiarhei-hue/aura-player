import SwiftUI

// MARK: - Полноэкранная анимация жидкостной волны при встряхивании телефона
// (Apple Music & Liquid Glass: концентрические световые кольца в цветах обложки трека)

struct WaveShakeOverlayView: View {
    let isActive: Bool
    let triggerCount: Int
    let palette: [Color]
    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    @State private var waveProgress: CGFloat = 0.0
    @State private var ambientFlashOpacity: Double = 0.0
    @State private var hudVisible: Bool = false
    @State private var sparkleRotation: Double = 0.0

    private var primaryColor: Color {
        if let first = palette.first {
            return first
        }
        return Color(red: 0.0, green: 0.95, blue: 0.99) // #00F2FE Electric Cyan
    }

    private var secondaryColor: Color {
        if palette.count > 1 {
            return palette[1]
        }
        return Color(red: 0.31, green: 0.67, blue: 0.99) // #4FACFE Deep Azure
    }

    private var accentColor: Color {
        if palette.count > 2 {
            return palette[2]
        }
        return Color(red: 0.98, green: 0.88, blue: 0.16) // #FBE029 Signature Glow
    }

    var body: some View {
        ZStack {
            if isActive {
                // 1. Полноэкранная вспышка атмосферного свечения в цветах обложки
                RadialGradient(
                    colors: [
                        primaryColor.opacity(0.38),
                        secondaryColor.opacity(0.22),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 550
                )
                .blur(radius: 65)
                .opacity(ambientFlashOpacity)
                .ignoresSafeArea()

                // 2. Расходящиеся жидкостные световые кольца волны
                GeometryReader { geo in
                    let maxSide = max(geo.size.width, geo.size.height)
                    ZStack {
                        // Внешнее глубокое кольцо (Primary)
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        primaryColor.opacity(0.95),
                                        secondaryColor.opacity(0.60),
                                        primaryColor.opacity(0.20)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(2, 22 * (1.0 - waveProgress))
                            )
                            .frame(width: maxSide * 1.35, height: maxSide * 1.35)
                            .scaleEffect(max(0.01, waveProgress * 1.25))
                            .opacity(Double(max(0.0, 1.0 - waveProgress * 0.92)))
                            .blur(radius: 18 * waveProgress)

                        // Среднее яркое кольцо (Secondary + Accent)
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        accentColor.opacity(0.95),
                                        primaryColor.opacity(0.75),
                                        secondaryColor.opacity(0.40)
                                    ],
                                    startPoint: .bottomLeading,
                                    endPoint: .topTrailing
                                ),
                                lineWidth: max(1.5, 14 * (1.0 - waveProgress))
                            )
                            .frame(width: maxSide * 1.05, height: maxSide * 1.05)
                            .scaleEffect(max(0.01, waveProgress * 1.10))
                            .opacity(Double(max(0.0, 1.0 - waveProgress * 0.85)))
                            .blur(radius: 10 * waveProgress)

                        // Тонкий сверкающий каустический гребень волны (Specular highlight)
                        Circle()
                            .strokeBorder(
                                Color.white.opacity(0.90),
                                lineWidth: max(1.0, 3.5 * (1.0 - waveProgress))
                            )
                            .frame(width: maxSide * 0.85, height: maxSide * 0.85)
                            .scaleEffect(max(0.01, waveProgress * 0.95))
                            .opacity(Double(max(0.0, 1.0 - waveProgress * 0.80)))
                            .blur(radius: 3 * waveProgress)
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.38)
                }
                .ignoresSafeArea()

                // 3. Парящий Liquid Glass HUD-бейдж вверху экрана
                VStack {
                    if hudVisible {
                        hudCard
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, 14)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: triggerCount) { _, _ in
            startWaveAnimation()
        }
        .onAppear {
            if isActive {
                startWaveAnimation()
            }
        }
    }

    // MARK: - Парящий Glass HUD
    private var hudCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [primaryColor, secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: primaryColor.opacity(0.65), radius: 8, y: 2)

                Image(systemName: "waveform.badge.sparkles")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(sparkleRotation))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .default))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.80))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial.opacity(0.92))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.65),
                            primaryColor.opacity(0.50),
                            .white.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: .black.opacity(0.50), radius: 18, y: 6)
        .shadow(color: primaryColor.opacity(0.35), radius: 12, y: 2)
    }

    // MARK: - Запуск физики волны
    private func startWaveAnimation() {
        waveProgress = 0.0
        ambientFlashOpacity = 0.0
        sparkleRotation = -30.0

        // 1. Быстрый всплеск свечения
        withAnimation(.easeOut(duration: 0.22)) {
            ambientFlashOpacity = 0.95
            hudVisible = true
            sparkleRotation = 15.0
        }

        // 2. Распространение жидкостной волны по экрану
        withAnimation(.easeOut(duration: 1.15)) {
            waveProgress = 1.0
            sparkleRotation = 0.0
        }

        // 3. Затухание вспышки
        withAnimation(.easeInOut(duration: 0.9).delay(0.25)) {
            ambientFlashOpacity = 0.0
        }

        // 4. Плавное закрытие HUD через 2.6 сек
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            withAnimation(.easeInOut(duration: 0.45)) {
                hudVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                onDismiss()
            }
        }
    }
}
