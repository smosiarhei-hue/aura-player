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
    case amethyst, cobalt, titanium, lime, mint, coral, silver

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .amethyst: return "Аметист"
        case .cobalt: return "Синий"
        case .titanium: return "Титан"
        case .lime: return "Лайм"
        case .mint: return "Мятный"
        case .coral: return "Коралл"
        case .silver: return "Серебро"
        }
    }
    var accentHex: UInt32 {
        switch self {
        case .amethyst: return 0x9875F5
        case .cobalt: return 0x527CFF
        case .titanium: return 0xF5A65B
        case .lime: return 0xC5EF68
        case .mint: return 0x69DFC2
        case .coral: return 0xFF806D
        case .silver: return 0xDCE3EF
        }
    }
    // Darker companions keep small labels, switches and tinted icons legible on white.
    var lightAccentHex: UInt32 {
        switch self {
        case .amethyst: return 0x6845B5
        case .cobalt: return 0x2852BA
        case .titanium: return 0x925019
        case .lime: return 0x4A6810
        case .mint: return 0x167260
        case .coral: return 0xAC4030
        case .silver: return 0x465163
        }
    }
    var darkCanvasHex: UInt32 {
        switch self {
        case .amethyst: return 0x0C0A12
        case .cobalt: return 0x090D16
        case .titanium: return 0x11100F
        case .lime: return 0x0D1009
        case .mint: return 0x071210
        case .coral: return 0x140B0B
        case .silver: return 0x0B0D11
        }
    }
    var lightCanvasHex: UInt32 {
        switch self {
        case .amethyst: return 0xF8F6FC
        case .cobalt: return 0xF5F7FC
        case .titanium: return 0xFAF7F3
        case .lime: return 0xF7FAF1
        case .mint: return 0xF2FAF7
        case .coral: return 0xFCF6F4
        case .silver: return 0xF5F7FA
        }
    }
    var swatchColor: Color { Color(uiColor: Self.uiColor(accentHex)) }
    var color: Color { Self.adaptive(light: Self.uiColor(lightAccentHex), dark: Self.uiColor(accentHex)) }
    var canvasColor: Color { Self.adaptive(light: Self.uiColor(lightCanvasHex), dark: Self.uiColor(darkCanvasHex)) }
    var darkCanvasColor: Color { Color(uiColor: Self.uiColor(darkCanvasHex)) }
    var flameColor: Color { color.opacity(0.78) }

    /// One-time migration of the six previous accents; nothing else in defaults is reset.
    static func restored(from saved: String?) -> AppThemeColor {
        if let saved, let current = Self(rawValue: saved) { return current }
        switch saved {
        case "crimson": return .coral
        case "sunset": return .titanium
        case "violet": return .amethyst
        case "cyan", "emerald": return .mint
        default: return .amethyst
        }
    }
    private nonisolated static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    // SwiftUI's AsyncRenderer may invoke this provider off MainActor. Capture values only.
    private nonisolated static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self { case .system: "Система"; case .light: "Светлый"; case .dark: "Тёмный" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
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

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "settings.appearance") }
    }

    private init() {
        if let savedFont = UserDefaults.standard.string(forKey: "settings.selectedFont"),
           let font = AppCustomFont(rawValue: savedFont) {
            self.selectedFont = font
        } else {
            self.selectedFont = .neueMontreal
        }

        self.selectedTheme = AppThemeColor.restored(from: defaults.string(forKey: "settings.selectedTheme"))
        defaults.set(selectedTheme.rawValue, forKey: "settings.selectedTheme")
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: "settings.appearance") ?? "") ?? .system
    }

    // Dynamic Colors
    var accentColor: Color { selectedTheme.color }
    var canvasColor: Color { selectedTheme.canvasColor }
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
