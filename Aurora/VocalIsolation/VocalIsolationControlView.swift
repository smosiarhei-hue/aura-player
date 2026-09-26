// Path: Aurora/VocalIsolation/VocalIsolationControlView.swift

import SwiftUI

// MARK: - Layout Configuration
public enum VocalIsolationUIConfig {
    /// Corner alignment on top of album artwork
    public static let cornerAlignment: Alignment = .bottomTrailing
    /// Edge insets from cover borders
    public static let cornerPadding: CGFloat = 14
    /// Expanded capsule dimensions matching reference design
    public static let capsuleWidth: CGFloat = 50
    public static let expandedHeight: CGFloat = 132
    public static let collapsedHeight: CGFloat = 50
}

// MARK: - Vocal Isolation Capsule Control View
//
// Real-time Apple Music Sing-style vertical pill slider overlay.
// Faithfully implements the user-provided reference design (media_1790343985298.png):
// - Translucent frosted glass dark capsule container
// - Bottom-to-top dynamic white fill level representing vocal attenuation
// - Custom stylized microphone icon with accent sparkles
// - Smooth vertical drag gesture with haptic feedback and click-free audio ramp

struct VocalIsolationControlView: View {
    @State private var manager = VocalIsolationManager.shared
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartLevel: Float = 0
    @State private var isDragging: Bool = false

    private var currentLevel: Float {
        manager.isolationLevel
    }

    private var fillFraction: CGFloat {
        CGFloat(max(0.0, min(1.0, currentLevel)))
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.isExpanded {
                expandedCapsuleSlider
            } else {
                collapsedIconButton
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: manager.isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Изоляция вокала")
        .accessibilityValue("\(Int(currentLevel * 100)) процентов")
    }

    // MARK: - Expanded Vertical Capsule Slider

    private var expandedCapsuleSlider: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let fillHeight = max(0, min(totalHeight, totalHeight * fillFraction))

            ZStack(alignment: .bottom) {
                // 1. Frosted Dark Capsule Background
                Capsule()
                    .fill(Color(red: 0.16, green: 0.14, blue: 0.13).opacity(0.88))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.40), radius: 10, y: 5)

                // 2. Dynamic Bottom-to-Top White Fill
                Capsule()
                    .fill(Color.white)
                    .frame(height: fillHeight)
                    .clipShape(Capsule())

                // 3. Bottom Centered Microphone + Sparkles Icon
                VStack {
                    Spacer()
                    stylizedMicrophoneIcon(isFilled: fillFraction > 0.32)
                        .frame(width: VocalIsolationUIConfig.capsuleWidth, height: VocalIsolationUIConfig.capsuleWidth)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap(.medium)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                if manager.isolationLevel > 0.05 {
                                    manager.isolationLevel = 0.0
                                } else {
                                    manager.isolationLevel = 0.85
                                }
                            }
                        }
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartLevel = manager.isolationLevel
                            Haptics.tap(.light)
                        }
                        // Dragging upwards increases isolation (fill goes up)
                        let deltaY = -value.translation.height
                        let deltaFraction = Float(deltaY / (totalHeight - 20))
                        let newLevel = max(0.0, min(1.0, dragStartLevel + deltaFraction))
                        if abs(newLevel - manager.isolationLevel) > 0.01 {
                            manager.isolationLevel = newLevel
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        Haptics.tap(.light)
                        // If pulled down to 0, keep expanded so user can see it or tap to close
                    }
            )
        }
        .frame(width: VocalIsolationUIConfig.capsuleWidth, height: VocalIsolationUIConfig.expandedHeight)
        .overlay(alignment: .topTrailing) {
            // Dismiss button on double-tap or top tap
            Button {
                Haptics.tap(.light)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                    manager.isExpanded = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(fillFraction > 0.88 ? Color.black.opacity(0.6) : Color.white.opacity(0.6))
                    .padding(.top, 7)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: - Collapsed Icon Button

    private var collapsedIconButton: some View {
        Button {
            Haptics.tap(.medium)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                manager.isExpanded = true
                if manager.isolationLevel < 0.05 {
                    manager.isolationLevel = 0.85
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(red: 0.16, green: 0.14, blue: 0.13).opacity(0.85))
                    .overlay(
                        Circle()
                            .strokeBorder(
                                manager.isolationLevel > 0.05
                                    ? Color.white.opacity(0.55)
                                    : Color.white.opacity(0.18),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                stylizedMicrophoneIcon(isFilled: manager.isolationLevel > 0.05)
            }
            .frame(width: VocalIsolationUIConfig.collapsedHeight, height: VocalIsolationUIConfig.collapsedHeight)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Original Stylized Microphone + Sparkles Graphic

    private func stylizedMicrophoneIcon(isFilled: Bool) -> some View {
        ZStack {
            // Main tilted microphone
            Image(systemName: "mic.fill")
                .font(.system(size: 19, weight: .bold))
                .rotationEffect(.degrees(-35))
                .offset(x: -3, y: -2)

            // Accent sparkles / stars in bottom right of the mic
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .offset(x: 10, y: 7)
                .opacity(0.85)

            Image(systemName: "sparkle")
                .font(.system(size: 6, weight: .semibold))
                .offset(x: 4, y: 12)
                .opacity(0.60)
        }
        .foregroundStyle(isFilled ? Color(red: 0.13, green: 0.12, blue: 0.11) : Color.white)
    }
}
