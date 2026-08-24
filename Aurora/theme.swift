import SwiftUI

// MARK: - Settings

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
    case aurora, violet, sunset, mint, rose
    var id: String { rawValue }
    var name: String {
        switch self {
        case .aurora: return "Аврора"
        case .violet: return "Фиалка"
        case .sunset: return "Закат"
        case .mint:   return "Мята"
        case .rose:   return "Роза"
        }
    }
    var colors: [Color] {
        switch self {
        case .aurora: return [Color(hex: "#2DD4BF")!, Color(hex: "#6366F1")!]
        case .violet: return [Color(hex: "#8B5CF6")!, Color(hex: "#D946EF")!]
        case .sunset: return [Color(hex: "#F97316")!, Color(hex: "#EC4899")!]
        case .mint:   return [Color(hex: "#34D399")!, Color(hex: "#0EA5E9")!]
        case .rose:   return [Color(hex: "#FB7185")!, Color(hex: "#F59E0B")!]
        }
    }
    var main: Color { colors[0] }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "settings.theme") } }
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "settings.accent") } }

    var colorScheme: ColorScheme? { theme.colorScheme }
    var accentColor: Color { accent.main }
    var accentGradient: LinearGradient {
        LinearGradient(colors: accent.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private init() {
        theme = AppTheme(rawValue: defaults.string(forKey: "settings.theme") ?? "") ?? .system
        accent = AccentChoice(rawValue: defaults.string(forKey: "settings.accent") ?? "") ?? .aurora
    }
}

// MARK: - Glass card modifier

struct GlassCard: ViewModifier {
    var corner: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(corner: CGFloat = 22) -> some View { modifier(GlassCard(corner: corner)) }
}

// MARK: - Dynamic backdrop (player screen background)

struct BackdropView: View {
    var palette: [Color]
    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08)
            Circle()
                .fill(palette.count > 0 ? palette[0] : .teal)
                .frame(width: 420, height: 420)
                .blur(radius: 90)
                .offset(x: -110, y: -180)
            Circle()
                .fill(palette.count > 1 ? palette[1] : .indigo)
                .frame(width: 460, height: 460)
                .blur(radius: 100)
                .offset(x: 130, y: 120)
            if palette.count > 2 {
                Circle()
                    .fill(palette[2])
                    .frame(width: 380, height: 380)
                    .blur(radius: 90)
                    .offset(x: 40, y: -40)
                    .opacity(0.8)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 2.5), value: palette)
    }
}
