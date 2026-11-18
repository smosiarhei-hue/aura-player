import SwiftUI
import UIKit

/// Native Liquid Glass floating navigation bar for iOS 26/27 visionOS design.
/// Features a floating translucent capsule with Apple Liquid Glass material,
/// GPU-accelerated Metal specular rim, sliding morphing selection pill,
/// bouncy SF Symbols, tactile press feedback, and mechanical haptics.
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
        HStack(spacing: 3) {
            ForEach(availableTabs) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectTab(tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: isSelected ? 18.5 : 17, weight: isSelected ? .bold : .medium))
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
                    .frame(height: 50)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            accentColor.opacity(colorScheme == .dark ? 0.32 : 0.22),
                                            accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            LinearGradient(
                                                stops: [
                                                    .init(color: .white.opacity(colorScheme == .dark ? 0.50 : 0.65), location: 0.0),
                                                    .init(color: .white.opacity(0.12), location: 0.5),
                                                    .init(color: .clear, location: 1.0)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.85
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
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .glassEffect(.regular.interactive(), in: .capsule)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(colorScheme == .dark ? 0.55 : 0.70), location: 0.0),
                                    .init(color: .white.opacity(0.18), location: 0.25),
                                    .init(color: .white.opacity(0.04), location: 0.70),
                                    .init(color: .white.opacity(0.22), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .sonivoMetal(corner: 999, emphasis: 0.40)
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 26, x: 0, y: 12)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 6, x: 0, y: 2)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.75), value: selectedTab)
    }

    private func selectTab(_ tab: AppTab) {
        guard selectedTab != tab else { return }
        Haptics.tap(.light)
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.75)) {
            selectedTab = tab
        }
    }
}

/// Spring compression button style for liquid glass tab buttons.
struct LiquidTabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(SN.fastSpring, value: configuration.isPressed)
    }
}
