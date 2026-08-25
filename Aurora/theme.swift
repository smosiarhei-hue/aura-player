import SwiftUI

// MARK: - Settings & Appearance Store

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return "Как в системе"
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum AccentChoice: String, CaseIterable, Codable, Identifiable {
    case aurora, neon, sunset, emerald, cyber
    var id: String { rawValue }
    var name: String {
        switch self {
        case .aurora:  return "Aurora"
        case .neon:    return "Neon Glow"
        case .sunset:  return "Sunset"
        case .emerald: return "Emerald"
        case .cyber:   return "Cyber"
        }
    }
    var colors: [Color] {
        switch self {
        case .aurora:  return [Color(hex: "#2DD4BF")!, Color(hex: "#6366F1")!]
        case .neon:    return [Color(hex: "#EC4899")!, Color(hex: "#8B5CF6")!]
        case .sunset:  return [Color(hex: "#F97316")!, Color(hex: "#E11D48")!]
        case .emerald: return [Color(hex: "#10B981")!, Color(hex: "#06B6D4")!]
        case .cyber:   return [Color(hex: "#3B82F6")!, Color(hex: "#A855F7")!]
        }
    }
    var main: Color { colors[0] }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "settings.theme") } }
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "settings.accent") } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "settings.haptics") } }
    @Published var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }

    var colorScheme: ColorScheme? { theme.colorScheme }
    var accentColor: Color { accent.main }
    var accentGradient: LinearGradient {
        LinearGradient(colors: accent.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private init() {
        theme = AppTheme(rawValue: defaults.string(forKey: "settings.theme") ?? "") ?? .dark
        accent = AccentChoice(rawValue: defaults.string(forKey: "settings.accent") ?? "") ?? .aurora
        hapticsEnabled = defaults.object(forKey: "settings.haptics") as? Bool ?? true
        scrubHapticsEnabled = defaults.object(forKey: "settings.scrubHaptics") as? Bool ?? true
    }
}

// MARK: - iOS 27 Liquid Glass Modifiers & Cards

struct LiquidGlassModifier: ViewModifier {
    var corner: CGFloat = 24
    var padding: CGFloat = 0
    var opacity: CGFloat = 0.85

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(opacity)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.35),
                                .white.opacity(0.10),
                                .white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func liquidGlass(corner: CGFloat = 24, padding: CGFloat = 0, opacity: CGFloat = 0.85) -> some View {
        modifier(LiquidGlassModifier(corner: corner, padding: padding, opacity: opacity))
    }
}
