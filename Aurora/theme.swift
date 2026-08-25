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

// MARK: - iOS 27 Liquid Glass

struct LiquidGlassModifier: ViewModifier {
    var corner: CGFloat = 28
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: corner, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.45),
                                .white.opacity(0.08),
                                .white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}

extension View {
    func liquidGlass(corner: CGFloat = 28, padding: CGFloat = 0) -> some View {
        modifier(LiquidGlassModifier(corner: corner, padding: padding))
    }
}

// MARK: - Dynamic backdrop (player screen background)

struct BackdropView: View {
    var palette: [Color]
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.06)
            ForEach(0..<3, id: \.self) { i in
                let c = palette.indices.contains(i) ? palette[i] : (i == 0 ? Color.teal : Color.indigo)
                Circle()
                    .fill(c.opacity(0.7))
                    .frame(width: CGFloat(380 + i * 40), height: CGFloat(380 + i * 40))
                    .blur(radius: CGFloat(80 + i * 20))
                    .offset(x: CGFloat(-120 + i * 130), y: CGFloat(-200 + i * 180))
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 2.5), value: palette)
    }
}

// MARK: - Old glassCard alias for backward compat

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
