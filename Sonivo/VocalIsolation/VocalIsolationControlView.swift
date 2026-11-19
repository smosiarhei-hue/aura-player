// Path: Sonivo/VocalIsolation/VocalIsolationControlView.swift

import SwiftUI

// MARK: - Layout Configuration
public enum VocalIsolationUIConfig {
    /// Corner alignment on top of album artwork
    public static let cornerAlignment: Alignment = .bottomTrailing
    /// Edge insets from cover borders
    public static let cornerPadding: CGFloat = 14
    /// Resting slim width and expanded interaction width (Apple Music Sing / iOS 27 Liquid Glass)
    public static let restingWidth: CGFloat = 36
    public static let capsuleWidth: CGFloat = 50
    public static let expandedHeight: CGFloat = 132
    public static let collapsedHeight: CGFloat = 46
}

// MARK: - Vocal Isolation Capsule Control View
//
// Real-time Apple Music Sing-style vertical Liquid Glass slider.
// Native iOS 26/27 visionOS design language:
// - Single clean Liquid Glass capsule track: translucent gray where inactive, solid white where active
// - Dynamic expansion: expands to 50pt wide when touched/dragged, smoothly shrinks to 36pt at rest
// - Embedded stylized microphone icon with sparkles that inverts to dark ink when covered by white fill
// - Click-free exponential audio parameter smoothing with multi-band stem protection

struct VocalIsolationControlView: View {
    @State private var manager = VocalIsolationManager.shared
    @State private var dragStartY: CGFloat = 0
    @State private var dragStartLevel: Float = 0
    @State private var isDragging: Bool = false
    @State private var autoCollapseTask: Task<Void, Never>?

    private var currentLevel: Float {
        manager.isolationLevel
    }

    private var fillFraction: CGFloat {
        CGFloat(max(0.0, min(1.0, currentLevel)))
    }

    private var activeWidth: CGFloat {
        isDragging ? VocalIsolationUIConfig.capsuleWidth : VocalIsolationUIConfig.restingWidth
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
        .onDisappear { autoCollapseTask?.cancel() }
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
                // 1. Single Native Liquid Glass Track (Translucent Gray Inactive Portion)
                Capsule()
                    .fill(.ultraThinMaterial)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .overlay(
                        Capsule()
                            .fill(Color(white: 0.22).opacity(0.65))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.42), location: 0.0),
                                        .init(color: .white.opacity(0.10), location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

                // 2. Pure Solid White Fill (Active Portion)
                Capsule()
                    .fill(Color.white)
                    .frame(height: fillHeight)
                    .clipShape(Capsule())

                // 3. Bottom Centered Microphone + Sparkles Icon
                VStack {
                    Spacer()
                    stylizedMicrophoneIcon(isFilled: fillFraction > 0.28)
                        .frame(width: activeWidth, height: activeWidth)
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
            .scaleEffect(isDragging ? 1.04 : 1.0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        autoCollapseTask?.cancel()
                        if !isDragging {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                isDragging = true
                            }
                            dragStartLevel = manager.isolationLevel
                            Haptics.tap(.light)
                        }
                        // Dragging upwards increases isolation (fill goes up)
                        let deltaY = -value.translation.height
                        let deltaFraction = Float(deltaY / (totalHeight - 16))
                        let newLevel = max(0.0, min(1.0, dragStartLevel + deltaFraction))
                        if abs(newLevel - manager.isolationLevel) > 0.01 {
                            manager.isolationLevel = newLevel
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            isDragging = false
                        }
                        Haptics.tap(.light)
                        // Auto-collapse after 2.5s of inactivity so lyrics remain unobstructed
                        autoCollapseTask?.cancel()
                        autoCollapseTask = Task { @MainActor in
                            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
                            guard !isDragging else { return }
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                                manager.isExpanded = false
                            }
                        }
                    }
            )
        }
        .frame(width: activeWidth, height: VocalIsolationUIConfig.expandedHeight)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isDragging)
        .overlay(alignment: .topTrailing) {
            if isDragging || currentLevel > 0.05 {
                Button {
                    Haptics.tap(.light)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        manager.isExpanded = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(fillFraction > 0.88 ? Color.black.opacity(0.65) : Color.white.opacity(0.65))
                        .padding(.top, 7)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    // MARK: - Collapsed Icon Button (Native Liquid Glass Circle)

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
                    .fill(.ultraThinMaterial)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .overlay(
                        Circle()
                            .fill(Color(white: 0.20).opacity(0.70))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(manager.isolationLevel > 0.05 ? 0.65 : 0.35), location: 0.0),
                                        .init(color: .white.opacity(0.08), location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                stylizedMicrophoneIcon(isFilled: manager.isolationLevel > 0.05)
            }
            .frame(width: VocalIsolationUIConfig.collapsedHeight, height: VocalIsolationUIConfig.collapsedHeight)
        }
        .buttonStyle(TactileButtonStyle(scale: 0.94))
    }

    // MARK: - Stylized Microphone + Sparkles Graphic

    private func stylizedMicrophoneIcon(isFilled: Bool) -> some View {
        ZStack {
            // Main tilted microphone
            Image(systemName: "mic.fill")
                .font(.system(size: isDragging ? 18 : 15, weight: .bold))
                .rotationEffect(.degrees(-35))
                .offset(x: -2, y: -2)

            // Accent sparkles / stars in bottom right of the mic
            Image(systemName: "sparkle")
                .font(.system(size: isDragging ? 9 : 7.5, weight: .bold))
                .offset(x: isDragging ? 9 : 7, y: isDragging ? 6 : 5)
                .opacity(0.85)

            Image(systemName: "sparkle")
                .font(.system(size: isDragging ? 5.5 : 4.5, weight: .semibold))
                .offset(x: isDragging ? 4 : 3, y: isDragging ? 10 : 8)
                .opacity(0.60)
        }
        .foregroundStyle(isFilled ? Color(red: 0.11, green: 0.11, blue: 0.13) : Color.white)
        .animation(.easeInOut(duration: 0.15), value: isFilled)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isDragging)
    }
}
