import SwiftUI

// MARK: - Aurora Glass / iOS 27 Design System Tokens & Storage

enum AG {
    static let radius: CGFloat = 26
    static let blurPx: CGFloat = 26
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.72)
    static let fastSpring = Animation.spring(response: 0.18, dampingFraction: 0.75)
    static let slowSpring = Animation.spring(response: 0.62, dampingFraction: 0.70)

    // Palette tokens
    static let bg = Color(hex: "#070A18") ?? .black
    static let ink = Color(hex: "#F2F5FF") ?? .white
    static let ice = Color(hex: "#7CF6FF") ?? .cyan
    static let lavender = Color(hex: "#9A7CFF") ?? .purple
    static let magenta = Color(hex: "#FF8AD1") ?? .pink
}

enum AccentChoice: String, CaseIterable, Codable, Identifiable {
    case aurora, neon, sunset, emerald, cyber
    var id: String { rawValue }
    var name: String {
        switch self {
        case .aurora:  return "Aurora (Лёд & Лаванда)"
        case .neon:    return "Neon (Магента)"
        case .sunset:  return "Sunset (Закат)"
        case .emerald: return "Emerald (Изумруд)"
        case .cyber:   return "Cyber (Неон)"
        }
    }
    var colors: [Color] {
        switch self {
        case .aurora:  return [AG.ice, AG.lavender, AG.magenta]
        case .neon:    return [Color(hex: "#EC4899")!, Color(hex: "#8B5CF6")!]
        case .sunset:  return [Color(hex: "#F97316")!, Color(hex: "#E11D48")!]
        case .emerald: return [Color(hex: "#10B981")!, Color(hex: "#06B6D4")!]
        case .cyber:   return [Color(hex: "#3B82F6")!, Color(hex: "#A855F7")!]
        }
    }
    var main: Color { colors[0] }
}

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return "Как в системе"
        case .dark: return "Тёмная (Aurora Studio)"
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

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "settings.theme") } }
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "settings.accent") } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "settings.haptics") } }
    @Published var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }

    // Karaoke lyrics
    @Published var lyricsFontSize: Double { didSet { defaults.set(lyricsFontSize, forKey: "lyrics.fontSize") } }
    @Published var lyricsHighlightHex: String { didSet { defaults.set(lyricsHighlightHex, forKey: "lyrics.highlight") } }
    @Published var lyricsOffset: Double { didSet { defaults.set(lyricsOffset, forKey: "lyrics.offset") } }
    @Published var showTeleprompterInPlayer: Bool { didSet { defaults.set(showTeleprompterInPlayer, forKey: "lyrics.showInPlayer") } }

    var lyricsHighlightColor: Color { Color(hex: lyricsHighlightHex) ?? .pink }

    struct LyricsHighlightPreset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let lyricsHighlightPresets: [LyricsHighlightPreset] = [
        LyricsHighlightPreset(name: "Коралл", hex: "#FF455B"),
        LyricsHighlightPreset(name: "Неон", hex: "#7CF6FF"),
        LyricsHighlightPreset(name: "Лаванда", hex: "#9A7CFF"),
        LyricsHighlightPreset(name: "Магента", hex: "#EC4899"),
        LyricsHighlightPreset(name: "Изумруд", hex: "#10B981")
    ]

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
        lyricsFontSize = defaults.object(forKey: "lyrics.fontSize") as? Double ?? 46
        lyricsHighlightHex = defaults.string(forKey: "lyrics.highlight") ?? "#FF455B"
        lyricsOffset = defaults.object(forKey: "lyrics.offset") as? Double ?? 0
        showTeleprompterInPlayer = defaults.object(forKey: "lyrics.showInPlayer") as? Bool ?? true
    }
}

// MARK: - Official Aurora Glass Modifier (5-Layer Specular Liquid Glass)

struct AGGlassModifier: ViewModifier {
    var radius: CGFloat = AG.radius
    var padding: CGFloat = 0
    var opacity: CGFloat = 0.90

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(opacity)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.55), location: 0.0),
                                .init(color: AG.ice.opacity(0.35), location: 0.25),
                                .init(color: .clear, location: 0.55),
                                .init(color: Color.black.opacity(0.45), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .shadow(color: Color.black.opacity(0.30), radius: 20, x: 0, y: 10)
    }
}

extension View {
    func liquidGlass(corner: CGFloat = AG.radius, padding: CGFloat = 0, opacity: CGFloat = 0.90) -> some View {
        modifier(AGGlassModifier(radius: corner, padding: padding, opacity: opacity))
    }

    /// Native iOS 26 Liquid Glass.
    func glassOrMaterial(corner: CGFloat = AG.radius) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: corner))
    }

    /// Native iOS 26 glass capsule (for pills/docks).
    func glassCapsule() -> some View {
        self.glassEffect(.regular, in: .capsule)
    }
}
