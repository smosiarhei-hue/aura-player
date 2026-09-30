// Path: Sonivo/WaveShakeOverlayView.swift
// Полноэкранная 120 Гц жидкостная вертикальная волна перехода «Антигравити» (Apple ProMotion 120 FPS)
// Вдохновлено физикой Skiper UI 40 и Apple Human Interface Guidelines: кинетическая гидродинамика,
// расширяющиеся радиальные ударные волны и каустический гребень по всему экрану.

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

    // Длительность прохождения вертикальной волны через весь экран (кинематографичная глубина)
    private let waveDuration: TimeInterval = 1.25

    // Цвета приложения (строго без жёлтого)
    private var cleanPalette: (primary: Color, secondary: Color, accent: Color) {
        let defaultPrimary = Color(red: 0.0, green: 0.95, blue: 0.99)       // #00F2FE Electric Cyan
        let defaultSecondary = Color(red: 0.42, green: 0.49, blue: 1.0)     // #6B7CFF Royal Periwinkle / SN.accent
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
                        // от -22% высоты экрана (сверху) до +135% высоты экрана (внизу) — полное омовение экрана
                        let yCrest = -0.22 * h + progress * 1.57 * h
                        let colors = cleanPalette

                        ZStack {
                            // 0. Эпический радиальный гидродинамический импульс (Skiper UI Shockwave Pulse)
                            if rawProgress < 0.85 {
                                let shockProgress = min(1.0, rawProgress / 0.85)
                                let shockScale = 0.2 + shockProgress * 2.6
                                let shockOpacity = (1.0 - shockProgress) * 0.75

                                ZStack {
                                    Circle()
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [colors.primary, colors.secondary.opacity(0.8), colors.accent.opacity(0.4)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: max(1.5, 4.0 * (1.0 - shockProgress))
                                        )
                                        .scaleEffect(shockScale)
                                        .opacity(shockOpacity)
                                        .blur(radius: 2.0)

                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 2.0)
                                        .scaleEffect(shockScale * 0.92)
                                        .opacity(shockOpacity * 0.6)
                                        .blur(radius: 1.0)
                                }
                                .position(x: w / 2, y: h * 0.42)
                                .blendMode(.plusLighter)
                            }

                            // 1. Полноэкранное атмосферное омовение (Full-Viewport Liquid Wash)
                            if rawProgress < 0.99 {
                                let washHeight: CGFloat = 650
                                Rectangle()
                                    .fill(
                                        LinearGradient(
                                            stops: [
                                                .init(color: .clear, location: 0.0),
                                                .init(color: colors.primary.opacity(0.42 * (1.0 - rawProgress * 0.65)), location: 0.25),
                                                .init(color: colors.secondary.opacity(0.38 * (1.0 - rawProgress * 0.65)), location: 0.58),
                                                .init(color: colors.accent.opacity(0.28 * (1.0 - rawProgress * 0.65)), location: 0.88),
                                                .init(color: .clear, location: 1.0)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: w, height: washHeight)
                                    .position(x: w / 2, y: yCrest - washHeight * 0.28)
                                    .blur(radius: 45)
                            }

                            // 2. Вторичная запаздывающая жидкостная рябь (Trailing Liquid Wake)
                            if rawProgress > 0.03 && rawProgress < 0.96 {
                                Path { path in
                                    let yTrail = yCrest - 54.0
                                    drawWavePath(in: &path, width: w, yBase: yTrail, progress: progress + 0.16, amplitude: 26.0)
                                }
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            colors.accent.opacity(0.55 * (1.0 - rawProgress)),
                                            colors.primary.opacity(0.85 * (1.0 - rawProgress)),
                                            colors.secondary.opacity(0.50 * (1.0 - rawProgress))
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    lineWidth: 2.8
                                )
                                .blur(radius: 3.0)
                            }

                            // 3. Основное плотное тело вертикальной волны (Primary Fluid Wavefront)
                            if rawProgress < 0.99 {
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: 0))
                                    path.addLine(to: CGPoint(x: w, y: 0))
                                    path.addLine(to: CGPoint(x: w, y: calculateWaveY(x: w, width: w, yBase: yCrest, progress: progress, amplitude: 50.0)))

                                    // Отрисовка динамического волнистого гребня с высокой детализацией
                                    var x: CGFloat = w
                                    let step: CGFloat = 3.0
                                    while x >= 0 {
                                        let y = calculateWaveY(x: x, width: w, yBase: yCrest, progress: progress, amplitude: 50.0)
                                        path.addLine(to: CGPoint(x: x, y: y))
                                        x -= step
                                    }
                                    path.closeSubpath()
                                }
                                .fill(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: colors.primary.opacity(0.22 * (1.0 - rawProgress * 0.45)), location: 0.45),
                                            .init(color: colors.secondary.opacity(0.36 * (1.0 - rawProgress * 0.45)), location: 0.78),
                                            .init(color: colors.accent.opacity(0.60 * (1.0 - rawProgress * 0.45)), location: 1.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .blur(radius: 14)
                            }

                            // 4. Ведущий каустический гребень волны (Specular Liquid Crest Ribbon)
                            if rawProgress < 0.98 {
                                // Нижний рассеянный нектарный ореол
                                Path { path in
                                    drawWavePath(in: &path, width: w, yBase: yCrest, progress: progress, amplitude: 50.0)
                                }
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            colors.primary.opacity(0.95),
                                            colors.secondary.opacity(0.95),
                                            colors.accent.opacity(0.95)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 7.0, lineCap: .round, lineJoin: .round)
                                )
                                .blur(radius: 8.0)
                                .blendMode(.plusLighter)

                                // Верхняя ультра-яркая каустическая нить
                                Path { path in
                                    drawWavePath(in: &path, width: w, yBase: yCrest, progress: progress, amplitude: 50.0)
                                }
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            colors.primary.opacity(0.95),
                                            Color.white.opacity(0.98),
                                            colors.secondary.opacity(0.95),
                                            Color.white.opacity(0.98),
                                            colors.accent.opacity(0.95)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ),
                                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
                                )
                                .shadow(color: Color.white.opacity(0.90), radius: 8, y: 0)
                                .shadow(color: colors.primary.opacity(0.95), radius: 18, y: 2)
                                .blendMode(.plusLighter)
                            }

                            // 5. Вспышка на краях дисплея в момент кульминации (Vignette Edge Flash)
                            if rawProgress > 0.12 && rawProgress < 0.65 {
                                let edgeOpacity = sin((rawProgress - 0.12) / 0.53 * .pi) * 0.38
                                RoundedRectangle(cornerRadius: 48, style: .continuous)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [colors.primary.opacity(edgeOpacity), colors.secondary.opacity(edgeOpacity * 0.7)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 4
                                    )
                                    .blur(radius: 6)
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

    // MARK: - Математика жидкостной синусоидальной волны (Skiper Fluid Harmonics)

    private func calculateWaveY(x: CGFloat, width: CGFloat, yBase: CGFloat, progress: Double, amplitude: CGFloat) -> CGFloat {
        let normX = x / max(width, 1.0)
        // Композиция трех гармонических волн с бегущей фазой для естественной органики
        let wave1 = sin(normX * .pi * 2.6 + progress * 7.8) * amplitude
        let wave2 = cos(normX * .pi * 4.8 - progress * 5.8) * (amplitude * 0.44)
        let wave3 = sin(normX * .pi * 7.4 + progress * 9.6) * (amplitude * 0.22)
        return yBase + wave1 + wave2 + wave3
    }

    private func drawWavePath(in path: inout Path, width: CGFloat, yBase: CGFloat, progress: Double, amplitude: CGFloat) {
        let startY = calculateWaveY(x: 0, width: width, yBase: yBase, progress: progress, amplitude: amplitude)
        path.move(to: CGPoint(x: 0, y: startY))

        var currentX: CGFloat = 0
        let step: CGFloat = 3.0
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
                    .frame(width: 40, height: 40)
                    .shadow(color: colors.primary.opacity(0.70), radius: 10, y: 2)

                Image(systemName: "waveform.badge.sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(sparkleRotation))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy, design: .default))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(0.88))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial.opacity(0.94))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.75),
                            colors.primary.opacity(0.65),
                            colors.accent.opacity(0.40)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: .black.opacity(0.55), radius: 20, y: 6)
        .shadow(color: colors.primary.opacity(0.40), radius: 14, y: 2)
    }

    // MARK: - Запуск вертикальной волны

    private func startWaveAnimation() {
        animationStartTime = CACurrentMediaTime()
        sparkleRotation = -35.0

        withAnimation(.easeOut(duration: 0.22)) {
            hudVisible = true
            sparkleRotation = 18.0
        }

        withAnimation(.easeOut(duration: 0.65)) {
            sparkleRotation = 0.0
        }

        // Автозакрытие HUD через 2.4 секунды
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.35)) {
                hudVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onDismiss()
            }
        }
    }
}
