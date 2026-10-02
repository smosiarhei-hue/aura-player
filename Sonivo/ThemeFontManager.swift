import SwiftUI
import UIKit
import Observation

// MARK: - 5 Выбранных Шрифтов приложения (Apple Music & Modern Typography)
// 1. Neue Montreal — современный швейцарский чистый гротеск
// 2. Satoshi — геометрический санс с идеальными окружностями
// 3. General Sans — структурный, строгий современный гротеск
// 4. Instrument Sans — гуманистический открытый санс для музыки
// 5. PP Neue Machina — футуристический техно/моно стиль с характером

enum AppCustomFont: String, CaseIterable, Identifiable, Codable, Sendable {
    case neueMontreal = "neue_montreal"
    case satoshi = "satoshi"
    case generalSans = "general_sans"
    case instrumentSans = "instrument_sans"
    case ppNeueMachina = "pp_neue_machina"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neueMontreal: return "Neue Montreal"
        case .satoshi: return "Satoshi"
        case .generalSans: return "General Sans"
        case .instrumentSans: return "Instrument Sans"
        case .ppNeueMachina: return "PP Neue Machina"
        }
    }

    var subtitle: String {
        switch self {
        case .neueMontreal: return "Швейцарский современный гротеск"
        case .satoshi: return "Геометрический акцентный санс"
        case .generalSans: return "Структурный чистый гротеск"
        case .instrumentSans: return "Гуманистический открытый санс"
        case .ppNeueMachina: return "Футуристический техно / моно"
        }
    }

    var sampleText: String {
        switch self {
        case .neueMontreal: return "Aa Bb Gg 123"
        case .satoshi: return "Aa Qq Rr 456"
        case .generalSans: return "Aa Kk Ww 789"
        case .instrumentSans: return "Aa Jj Zz 012"
        case .ppNeueMachina: return "[Aa 01] Tech"
        }
    }

    func postscriptName(for weight: Font.Weight) -> String {
        switch self {
        case .neueMontreal:
            if weight == .bold || weight == .heavy || weight == .black {
                return "PPNeueMontreal-Bold"
            } else if weight == .medium || weight == .semibold {
                return "PPNeueMontreal-Medium"
            }
            return "PPNeueMontreal-Regular"
        case .satoshi:
            if weight == .bold || weight == .heavy || weight == .black {
                return "Satoshi-Bold"
            } else if weight == .medium || weight == .semibold {
                return "Satoshi-Medium"
            }
            return "Satoshi-Regular"
        case .generalSans:
            if weight == .bold || weight == .heavy || weight == .black {
                return "GeneralSans-Bold"
            } else if weight == .medium || weight == .semibold {
                return "GeneralSans-Medium"
            }
            return "GeneralSans-Regular"
        case .instrumentSans:
            if weight == .bold || weight == .heavy || weight == .black {
                return "InstrumentSans-Bold"
            } else if weight == .medium || weight == .semibold {
                return "InstrumentSans-SemiBold"
            }
            return "InstrumentSans-Regular"
        case .ppNeueMachina:
            if weight == .bold || weight == .heavy || weight == .black {
                return "PPNeueMachina-Ultrabold"
            } else if weight == .medium || weight == .semibold {
                return "PPNeueMachina-Medium"
            }
            return "PPNeueMachina-Regular"
        }
    }

    var fallbackDesign: Font.Design {
        switch self {
        case .neueMontreal: return .default
        case .satoshi: return .rounded
        case .generalSans: return .default
        case .instrumentSans: return .default
        case .ppNeueMachina: return .monospaced
        }
    }
}

// MARK: - Темы оформления и акцентных цветов

enum AppThemeColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case crimson = "crimson"
    case sunset = "sunset"
    case violet = "violet"
    case cyan = "cyan"
    case emerald = "emerald"
    case cobalt = "cobalt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crimson: return "Apple Crimson"
        case .sunset: return "Amber Sunset"
        case .violet: return "Electric Violet"
        case .cyan: return "Neon Cyan"
        case .emerald: return "Emerald Glow"
        case .cobalt: return "Cobalt Blue"
        }
    }

    var color: Color {
        switch self {
        case .crimson: return Color(hex: "#FF2D55") ?? .pink
        case .sunset: return Color(hex: "#F59E0B") ?? .orange
        case .violet: return Color(hex: "#8B5CF6") ?? .purple
        case .cyan: return Color(hex: "#06B6D4") ?? .cyan
        case .emerald: return Color(hex: "#10B981") ?? .green
        case .cobalt: return Color(hex: "#2563EB") ?? .blue
        }
    }

    var flameColor: Color {
        switch self {
        case .crimson: return Color(hex: "#FF375F") ?? .red
        case .sunset: return Color(hex: "#D97706") ?? .orange
        case .violet: return Color(hex: "#6D28D9") ?? .indigo
        case .cyan: return Color(hex: "#0891B2") ?? .teal
        case .emerald: return Color(hex: "#059669") ?? .green
        case .cobalt: return Color(hex: "#1D4ED8") ?? .blue
        }
    }
}

// MARK: - Центральный менеджер тем и типографики

@Observable
@MainActor
final class ThemeFontManager {
    static let shared = ThemeFontManager()
    private let defaults = UserDefaults.standard

    var selectedFont: AppCustomFont {
        didSet {
            defaults.set(selectedFont.rawValue, forKey: "settings.selectedFont")
        }
    }

    var selectedTheme: AppThemeColor {
        didSet {
            defaults.set(selectedTheme.rawValue, forKey: "settings.selectedTheme")
        }
    }

    private init() {
        if let savedFont = UserDefaults.standard.string(forKey: "settings.selectedFont"),
           let font = AppCustomFont(rawValue: savedFont) {
            self.selectedFont = font
        } else {
            self.selectedFont = .neueMontreal
        }

        if let savedTheme = UserDefaults.standard.string(forKey: "settings.selectedTheme"),
           let theme = AppThemeColor(rawValue: savedTheme) {
            self.selectedTheme = theme
        } else {
            self.selectedTheme = .crimson
        }
    }

    // Dynamic Colors
    var accentColor: Color { selectedTheme.color }
    var flameColor: Color { selectedTheme.flameColor }
    var heartColor: Color { Color(hex: "#FF2D55") ?? .pink }
    var emberGradient: LinearGradient {
        LinearGradient(colors: [accentColor, flameColor], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Dynamic Typography
    func font(style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        resolveFont(for: style, weight: weight)
    }

    func displayFont(style: Font.TextStyle = .title2, weight: Font.Weight = .bold) -> Font {
        resolveFont(for: style, weight: weight)
    }

    func roundedFont(style: Font.TextStyle = .body, weight: Font.Weight = .medium) -> Font {
        if selectedFont == .satoshi {
            return resolveFont(for: style, weight: weight)
        }
        return resolveFont(for: style, weight: weight, forceRounded: true)
    }

    private func resolveFont(for style: Font.TextStyle, weight: Font.Weight, forceRounded: Bool = false) -> Font {
        let size = pointSize(for: style)
        let font = selectedFont
        let psName = font.postscriptName(for: weight)

        if UIFont(name: psName, size: size) != nil || UIFont(name: font.displayName, size: size) != nil {
            return Font.custom(psName, size: size, relativeTo: style).weight(weight)
        }

        let design: Font.Design = forceRounded ? .rounded : font.fallbackDesign
        return Font.system(style, design: design, weight: weight)
    }

    private func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
}
