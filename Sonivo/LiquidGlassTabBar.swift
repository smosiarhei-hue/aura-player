import SwiftUI
import UIKit

/// Native Liquid Glass floating tab bar for iOS 26/27 visionOS-style navigation.
/// Displays a floating translucent capsule with specular liquid metal border,
/// animated sliding selection pill, SF Symbol bounce effects, and tactile feedback.
struct LiquidGlassTabBar: View {
    @Binding var selectedTab: AppTab
    let isLoggedIn: Bool
    var accentColor: Color = SN.accent
    var onGuestAction: (() -> Void)? = nil

    @Namespace private var tabNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var availableTabs: [AppTab] {
        if isLoggedIn {
            return [.home, .browse, .radio, .library, .search]
        } else {
            return [.home, .library, .search]
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(availableTabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectTab(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: isSelected ? 18 : 17, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? SN.ink : SN.inkMuted)
                            .symbolEffect(.bounce, value: isSelected)
                            .frame(height: 22)

                        Text(tab.label)
                            .font(SN.rounded(.caption2, isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? SN.ink : SN.inkMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            accentColor.opacity(colorScheme == .dark ? 0.28 : 0.18),
                                            accentColor.opacity(colorScheme == .dark ? 0.12 : 0.08)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(colorScheme == .dark ? 0.35 : 0.45),
                                                    Color.white.opacity(0.10),
                                                    Color.clear
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                )
                                .matchedGeometryEffect(id: "liquid_active_indicator", in: tabNamespace)
                        }
                    }
                }
                .buttonStyle(LiquidTabPressStyle())
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .glassEffect(.regular, in: .capsule)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.40 : 0.55),
                                    Color.white.opacity(0.14),
                                    Color.white.opacity(0.04),
                                    Color.white.opacity(0.20)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .sonivoMetal(corner: 999, emphasis: 0.35)
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.16), radius: 24, x: 0, y: 10)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 6, x: 0, y: 2)
        .animation(reduceMotion ? nil : SN.spring, value: selectedTab)
    }

    private func selectTab(_ tab: AppTab) {
        guard selectedTab != tab else { return }
        Haptics.tap(.light)
        withAnimation(reduceMotion ? nil : SN.spring) {
            selectedTab = tab
        }
    }
}

/// Spring compression button style for liquid glass tab buttons.
struct LiquidTabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(SN.fastSpring, value: configuration.isPressed)
    }
}
