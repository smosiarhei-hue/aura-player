// Path: Aurora/WaveShakeOverlayView.swift
// Полноэкранная 120 Гц жидкостная вертикальная волна перехода «Антигравити» (Apple ProMotion 120 FPS)

import SwiftUI
import UIKit

// MARK: - Полноэкранная 120 Гц вертикальная волна при встряхивании

struct WaveShakeOverlayView: View {
    let isActive: Bool
    let triggerCount: Int
    let palette: [Color]
    let title: String
    let subtitle: String
    let onDismiss: () -> Void

    @State private var animationStartTime: TimeInterval = 0
    @State private var hudVisible: Bool = false
    @State private var sparkleRotation: Double = 0.0

    // Длительность прохождения вертикальной волны через весь экран
    private let waveDuration: TimeInterval = 0.92

    // Цвета приложения (строго без жёлтого)
    private var cleanPalette: (primary: Color, secondary: Color, accent: Color) {
        let defaultPrimary = Color(red: 0.0, green: 0.95, blue: 0.99)       // #00F2FE Electric Cyan
        let defaultSecondary = Color(red: 0.42, green: 0.49, blue: 1.0)     // #6B7CFF Royal Periwinkle / AG.accent
        let defaultAccent = Color(red: 0.62, green: 0.31, blue: 0.98)       // #9D4EDD Neon Aura Violet

        // Фильтрация палитры трека: категорически исключаем жёлтые и золотые оттенки
        let nonYellow = palette.filter { c in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
            // Желто-золотые тона (высокий R и G, низкий B)
            if r > 0.68 && g > 0.58 && b < 0.42 {
                return false
            }
            return true
        }

        let p = nonYellow.indices.contains(0) ? nonYellow[0] : defaultPrimary
        let s = nonYellow.indices.contains(1) ? nonYellow[1] : defaultSecondary
        let a = nonYellow.indices.contains(2) ? nonYellow[2] : defaultAccent
        return (p, s, a)
    }

    var body: some View {
        ZStack {
            if isActive {
                // Аппаратный 120 Гц рендер волны через TimelineView
                TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !isActive)) { timeline in
                    GeometryReader { geo in
                        let w = geo.size.width
                        let h = geo.size.height
                        let now = timeline.date.timeIntervalSinceReferenceDate
                        let elapsed = animationStartTime > 0 ? (now - animationStartTime) : 0
                        let rawProgress = min(1.0, max(0.0, elapsed / waveDuration))
                        let progress = smoothStep(rawProgress)

                        // Текущая вертикальная позиция гребня волны:
                        // от -15% высоты экрана (сверху) до +120% высоты экрана (внизу)
                        let yCrest = -0.15 * h + progress * 1.35 * h
                        let colors = cleanPalette

                        ZStack {
                            // 1. Атмосферное вертикальное омовение экрана (Ambient Liquid Wash)
                            if rawProgress < 0.98 {
                                let washHeight: CGFloat = 420
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            stops: [
                                                .init(color: .clear, location: 0.0),
                                                .init(color: colors.primary.opacity(0.32 * (1.0 - rawProgress * 0.7)), location: 0.35),
                                                .init(color: colors.secondary.opacity(0.28 * (1.0 - rawProgress * 0.7)), location: 0.65),
                                                .init(color: colors.accent.opacity(0.18 * (1.0 - rawProgress * 0.7)), location: 0.90),
                                                .init(color: .clear, location: 1.0)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: w, height: washHeight)
                                    .position(x: w / 2, y: yCrest - washHeight * 0.25)
                                    .blur(radius: 40)
                            }

                            // 2. Вторичная запаздывающая жидкостная рябь (Trailing Liquid Wake)
                            if rawProgress > 0.05 && rawProgress < 0.95 {
                                Path { path in
                                    let yTrail = yCrest - 42.0
                                    drawWavePath(in: &path, width: w, yBase: yTrail, progress: progress + 0.12, amplitude: 14.0)
                                }
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            colors.accent.opacity(0.40 * (1.0 - rawProgress)),
                                            colors.primary.opacity(0.60 * (1.0 - rawProgress)),
                                            colors.secondary.opacity(0.35 * (1.0 - rawProgress))
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    lineWidth: 2.0
                                )
                                .blur(radius: 2.5)
                            }

                            // 3. Основное тело вертикальной волны (Primary Fluid Wavefront)
                            if rawProgress < 0.98 {
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: w, y: 0))
                                    path.addLine(to: CGPoint(x: w, y: calculateWaveY(x: w, width: w, yBase: yCrest, progress: progress, amplitude: 22.0)))

                                    // Отрисовка волнистого нижнего края
                                    var x: CGFloat = w
                                    let step: CGFloat = 4.0
                                    while x >= 0 {
                                        let y = calculateWaveY(x: x, width: w, yBase: yCrest, progress: progress, amplitude: 22.0)
                                        path.addLine(to: CGPoint(x: x, y: y))
                                        x -= step
                                    }
                                    path.closeSubpath()
                                }
                                .fill(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: colors.primary.opacity(0.12 * (1.0 - rawProgress * 0.5)), location: 0.50),
                                            .init(color: colors.secondary.opacity(0.24 * (1.0 - rawProgress * 0.5)), location: 0.82),
                                            .init(color: colors.accent.opacity(0.45 * (1.0 - rawProgress * 0.5)), location: 1.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .blur(radius: 12)
                            }

                            // 4. Ведущий каустический гребень волны (Specular Liquid Crest Ribbon)
                            if rawProgress < 0.96 {
                                Path { path in
                                    drawWavePath(in: &path, width: w, yBase: yCrest, progress: progress, amplitude: 22.0)
                                }
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            colors.primary.opacity(0.85),
                                            Color.white.opacity(0.98),
                                            colors.secondary.opacity(0.90),
                                            Color.white.opacity(0.98),
                                            colors.accent.opacity(0.85)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                                )
                                .shadow(color: Color.white.opacity(0.80), radius: 6, y: 0)
                                .shadow(color: colors.primary.opacity(0.90), radius: 14, y: 2)
                                .blendMode(.plusLighter)
                            }
                        }
                    }
                    .ignoresSafeArea()
                }
                .drawingGroup(opaque: false, colorMode: .extendedLinear)
                .ignoresSafeArea()

                // Парящий Liquid Glass HUD
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

    // MARK: - Математика жидкостной синусоидальной волны

    private func calculateWaveY(x: CGFloat, width: CGFloat, yBase: CGFloat, progress: Double, amplitude: CGFloat) -> CGFloat {
        let normX = x / max(width, 1.0)
        // Композиция двух гармонических волн с бегущей фазой
        let wave1 = sin(normX * .pi * 2.6 + progress * 7.5) * amplitude
        let wave2 = cos(normX * .pi * 4.2 - progress * 5.5) * (amplitude * 0.45)
        return yBase + wave1 + wave2
    }

    private func drawWavePath(in path: inout Path, width: CGFloat, yBase: CGFloat, progress: Double, amplitude: CGFloat) {
        let startY = calculateWaveY(x: 0, width: width, yBase: yBase, progress: progress, amplitude: amplitude)
        path.move(to: CGPoint(x: 0, y: startY))

        var currentX: CGFloat = 0
        let step: CGFloat = 4.0
        while currentX <= width {
            let y = calculateWaveY(x: currentX, width: width, yBase: yBase, progress: progress, amplitude: amplitude)
            path.addLine(to: CGPoint(x: currentX, y: y))
            currentX += step
        }
    }

    private func smoothStep(_ t: Double) -> Double {
        // Кубическая интерполяция гладкого ускорения и замедления (Smoothstep)
        let clamped = max(0.0, min(1.0, t))
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    // MARK: - Парящий Glass HUD в фирменных цветах Sonivo

    private var hudCard: some View {
        let colors = cleanPalette
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [colors.primary, colors.secondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .shadow(color: colors.primary.opacity(0.65), radius: 8, y: 2)

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
                    .foregroundStyle(.white.opacity(0.85))
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
                            .white.opacity(0.70),
                            colors.primary.opacity(0.60),
                            colors.accent.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: .black.opacity(0.50), radius: 18, y: 6)
        .shadow(color: colors.primary.opacity(0.35), radius: 12, y: 2)
    }

    // MARK: - Запуск вертикальной волны

    private func startWaveAnimation() {
        animationStartTime = CACurrentMediaTime()
        sparkleRotation = -30.0

        withAnimation(.easeOut(duration: 0.22)) {
            hudVisible = true
            sparkleRotation = 15.0
        }

        withAnimation(.easeOut(duration: 0.60)) {
            sparkleRotation = 0.0
        }

        // Автозакрытие HUD через 2.2 секунды
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeInOut(duration: 0.35)) {
                hudVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onDismiss()
            }
        }
    }
}
