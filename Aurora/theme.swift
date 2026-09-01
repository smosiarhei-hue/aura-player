import SwiftUI
import Observation

// MARK: - Sonivo Ember Design System (dark canvas + amber gradients + rounded display type)

enum AG {
    static let radius: CGFloat = 26
    static let blurPx: CGFloat = 26
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.72)
    static let fastSpring = Animation.spring(response: 0.18, dampingFraction: 0.75)
    static let slowSpring = Animation.spring(response: 0.62, dampingFraction: 0.70)

    // MARK: - Ember palette
    static let bg       = Color(hex: "#08070A") ?? .black
    static let bgRaised = Color(hex: "#100E13") ?? .black
    static let card     = Color(hex: "#17151A") ?? .black
    static let coal     = Color(hex: "#1E1B21") ?? .black
    static let ink      = Color(hex: "#F8F5F1") ?? .white
    static let inkMuted = Color(hex: "#A29A92") ?? .gray
    static let amber    = Color(hex: "#FBBF24") ?? .yellow
    static let ember    = Color(hex: "#F97316") ?? .orange
    static let flame    = Color(hex: "#EA580C") ?? .orange

    // Legacy tokens kept so older screens keep compiling
    static let ice      = Color(hex: "#7CF6FF") ?? .cyan
    static let lavender = Color(hex: "#9A7CFF") ?? .purple
    static let magenta  = Color(hex: "#FF8AD1") ?? .pink

    static var emberGradient: LinearGradient {
        LinearGradient(colors: [amber, ember, flame], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var emberWarm: LinearGradient {
        LinearGradient(colors: [flame, ember, amber], startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    static var hairline: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04), Color.black.opacity(0.22)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    // MARK: - Typography (Apple Music iOS Standard SF Pro)
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func serifAccent(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}

// MARK: - Native Apple Music HDR Shimmer & Pure Luster Modifier (Zero Ghosting)

struct HDRShimmerModifier: ViewModifier {
    let isActive: Bool
    @State private var phase: CGFloat = -0.8

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Color.white.opacity(0.65), location: 0.50),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .rotationEffect(.degrees(25))
                    .offset(x: phase * 180)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                )
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                        phase = 0.8
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func hdrShimmer(isActive: Bool = true) -> some View {
        modifier(HDRShimmerModifier(isActive: isActive))
    }
}

// MARK: - Ember Backdrop

struct EmberBackdrop: View {
    var body: some View {
        ZStack {
            AG.bg
            RadialGradient(gradient: Gradient(colors: [AG.flame.opacity(0.34), AG.ember.opacity(0.10), Color.clear]),
                           center: UnitPoint(x: 0.5, y: -0.03),
                           startRadius: 0,
                           endRadius: 500)
            RadialGradient(gradient: Gradient(colors: [AG.amber.opacity(0.10), Color.clear]),
                           center: UnitPoint(x: 0.04, y: 0.34),
                           startRadius: 0,
                           endRadius: 320)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Ember surfaces

struct EmberCardModifier: ViewModifier {
    var corner: CGFloat = 20
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(AG.card.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(AG.hairline, lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 8)
    }
}

struct EmberGlassModifier: ViewModifier {
    var corner: CGFloat = 22
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.black.opacity(0.42))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(AG.hairline, lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 9)
    }
}

extension View {
    func emberCard(corner: CGFloat = 20, padding: CGFloat = 0) -> some View {
        modifier(EmberCardModifier(corner: corner, padding: padding))
    }

    func emberGlass(corner: CGFloat = 22, padding: CGFloat = 0) -> some View {
        modifier(EmberGlassModifier(corner: corner, padding: padding))
    }
}

// MARK: - Reusable Ember controls

struct EmberSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var size: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AG.display(size, .bold))
                .foregroundStyle(AG.ink)
            if let subtitle {
                Text(subtitle)
                    .font(AG.text(12, .medium))
                    .foregroundStyle(AG.inkMuted)
            }
        }
    }
}

struct EmberPill: View {
    let title: String
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(AG.text(12, .semibold))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(AG.amber)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(AG.ember.opacity(0.14)))
        .overlay(Capsule().strokeBorder(AG.ember.opacity(0.32), lineWidth: 0.8))
    }
}

struct EmberChip: View {
    let title: String
    let icon: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(AG.text(13, isActive ? .bold : .medium))
        }
        .foregroundStyle(isActive ? Color.black.opacity(0.86) : AG.inkMuted)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(isActive ? AnyShapeStyle(AG.emberGradient) : AnyShapeStyle(Color.white.opacity(0.07)))
        )
        .overlay(
            Capsule().strokeBorder(isActive ? Color.clear : Color.white.opacity(0.10), lineWidth: 0.8)
        )
    }
}

struct EmberEyebrow: View {
    let text: String
    var color: Color = AG.inkMuted

    var body: some View {
        Text(text.uppercased())
            .font(AG.text(10, .heavy))
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

// MARK: - Accent & theme choices

enum AccentChoice: String, CaseIterable, Codable, Identifiable {
    case ember, aurora, neon, sunset, emerald, cyber
    var id: String { rawValue }
    var name: String {
        switch self {
        case .ember:   return "Ember (Янтарь и пламя)"
        case .aurora:  return "Aurora (Лёд и лаванда)"
        case .neon:    return "Neon (Магента)"
        case .sunset:  return "Sunset (Закат)"
        case .emerald: return "Emerald (Изумруд)"
        case .cyber:   return "Cyber (Неон)"
        }
    }
    var colors: [Color] {
        switch self {
        case .ember:   return [AG.amber, AG.ember, AG.flame]
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
        case .dark: return "Тёмная (Ember Studio)"
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

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "settings.theme") } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "settings.accent") } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "settings.haptics") } }
    var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }

    // Karaoke lyrics
    var lyricsFontSize: Double { didSet { defaults.set(lyricsFontSize, forKey: "lyrics.fontSize") } }
    var lyricsHighlightHex: String { didSet { defaults.set(lyricsHighlightHex, forKey: "lyrics.highlight") } }
    var lyricsOffset: Double { didSet { defaults.set(lyricsOffset, forKey: "lyrics.offset") } }
    var showTeleprompterInPlayer: Bool { didSet { defaults.set(showTeleprompterInPlayer, forKey: "lyrics.showInPlayer") } }

    var lyricsHighlightColor: Color { Color(hex: lyricsHighlightHex) ?? .orange }

    struct LyricsHighlightPreset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let lyricsHighlightPresets: [LyricsHighlightPreset] = [
        LyricsHighlightPreset(name: "Янтарь", hex: "#FBBF24"),
        LyricsHighlightPreset(name: "Пламя", hex: "#F97316"),
        LyricsHighlightPreset(name: "Коралл", hex: "#FF455B"),
        LyricsHighlightPreset(name: "Неон", hex: "#7CF6FF"),
        LyricsHighlightPreset(name: "Лаванда", hex: "#9A7CFF"),
        LyricsHighlightPreset(name: "Изумруд", hex: "#10B981")
    ]

    var colorScheme: ColorScheme? { theme.colorScheme }
    var accentColor: Color { accent.main }
    var accentGradient: LinearGradient {
        LinearGradient(colors: accent.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private init() {
        theme = AppTheme(rawValue: defaults.string(forKey: "settings.theme") ?? "") ?? .dark
        accent = AccentChoice(rawValue: defaults.string(forKey: "settings.accent") ?? "") ?? .ember
        hapticsEnabled = defaults.object(forKey: "settings.haptics") as? Bool ?? true
        scrubHapticsEnabled = defaults.object(forKey: "settings.scrubHaptics") as? Bool ?? true
        lyricsFontSize = defaults.object(forKey: "lyrics.fontSize") as? Double ?? 46
        lyricsHighlightHex = defaults.string(forKey: "lyrics.highlight") ?? "#FBBF24"
        lyricsOffset = defaults.object(forKey: "lyrics.offset") as? Double ?? 0
        showTeleprompterInPlayer = defaults.object(forKey: "lyrics.showInPlayer") as? Bool ?? true
    }
}

// MARK: - Aurora Glass Modifier (5-Layer Specular Liquid Glass)

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
                                .init(color: AG.amber.opacity(0.35), location: 0.25),
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
