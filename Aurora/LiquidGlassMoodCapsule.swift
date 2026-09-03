import SwiftUI

// MARK: - Liquid Glass Mood Capsule (по референсу фото 2: media_1788447855900.png)
// Ультрареалистичная горизонтальная капсула из жидкого стекла:
// - Слева: выпуклая 3D стеклянная сфера с тисненой иконкой настроения
// - По центру: 2-строчный нативный заголовок
// - Справа: круглая стеклянная кнопка со стрелкой >

struct LiquidGlassMoodCapsule: View {
    let preset: MoodPreset
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // 1. Левая выпуклая 3D-сфера из стекла с тисненой иконкой
                glassOrbView
                    .frame(width: 86, height: 86)
                    .padding(.leading, 6)

                // 2. Двустрочный текст настроения
                Text(preset.title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                // 3. Правая круглая стеклянная кнопка с шевроном >
                glassChevronButton
                    .frame(width: 48, height: 48)
                    .padding(.trailing, 14)
            }
            .padding(.vertical, 8)
            .background(capsuleGlassBackground)
            .clipShape(Capsule())
            .overlay(
                // Верхний стеклянный блик (спекулярная каемка)
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.85), location: 0.0),
                                .init(color: Color.white.opacity(0.35), location: 0.25),
                                .init(color: Color.white.opacity(0.08), location: 0.65),
                                .init(color: Color.white.opacity(0.40), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 10)
            .shadow(color: (Color(hex: preset.gradientColors.first ?? "#FFFFFF") ?? .white).opacity(0.25), radius: 24, x: 0, y: 8)
        }
        .buttonStyle(GlassCapsulePressStyle())
    }

    // MARK: - Левая выпуклая 3D Сфера из стекла

    private var glassOrbView: some View {
        ZStack {
            let baseColor = Color(hex: preset.gradientColors.first ?? "#FF8AD1") ?? .pink
            let secondColor = Color(hex: preset.gradientColors.last ?? "#A855F7") ?? .purple

            // Внутреннее цветное сияние настроения
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            baseColor.opacity(0.45),
                            secondColor.opacity(0.20),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 42
                    )
                )

            // Стеклянная оболочка сферы с каустикой
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    // Двойной стеклянный контур с дисперсией
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.95), location: 0.0),
                                    .init(color: .white.opacity(0.20), location: 0.5),
                                    .init(color: .white.opacity(0.60), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.0
                        )
                )

            // Внутренний блик сферы
            Circle()
                .inset(by: 8)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )

            // Тисненая иконка в центре сферы
            Image(systemName: preset.iconName)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color.white.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.white.opacity(0.6), radius: 8, x: 0, y: 0)
                .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 2)
        }
    }

    // MARK: - Правая стеклянная кнопка со стрелкой >

    private var glassChevronButton: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.25),
                            Color.white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.65), Color.white.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                )

            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Фоновый материал капсулы

    private var capsuleGlassBackground: some View {
        ZStack {
            // Темное преломляющее основание
            Color.black.opacity(0.50)

            // Ультратонкое жидкое стекло
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.85)

            // Горизонтальный стеклянный рефлекс
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.18), location: 0.0),
                    .init(color: Color.white.opacity(0.04), location: 0.4),
                    .init(color: Color.clear, location: 0.6),
                    .init(color: Color.white.opacity(0.06), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Стиль нажатия с пружинным откликом

struct GlassCapsulePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
    }
}
