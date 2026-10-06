import SwiftUI
import UIKit
import Observation

// MARK: - Sonivo Design System
//
// One source of truth for colour, type, motion and surfaces. Views never
// hard-code hex values or point sizes: they pick a semantic token here so the
// whole app shifts together, scales with Dynamic Type and stays legible on
// every artwork-driven background.

enum SN {
    // MARK: Motion — exactly three springs, chosen by how big the moving thing is.
    /// Small controls: press feedback, toggles, chips.
    static let fastSpring = Animation.spring(response: 0.22, dampingFraction: 0.78)
    /// Default for layout changes and content swaps.
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.80)
    /// Large surfaces: artwork, sheets, whole-screen transitions.
    static let slowSpring = Animation.spring(response: 0.55, dampingFraction: 0.82)

    // MARK: Surfaces
    static let radius: CGFloat = 20
    static let radiusSmall: CGFloat = 12
    static let radiusLarge: CGFloat = 28

    // MARK: Canvas — system semantic colors resolve safely in SwiftUI rendering.
    private static func surface(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    static let bg       = surface(light: UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1), dark: .black)
    static let bgRaised = surface(light: .white, dark: UIColor(white: 0.07, alpha: 1))
    static let card     = surface(light: .white, dark: UIColor(white: 0.09, alpha: 1))
    static let coal     = surface(light: UIColor(white: 0.93, alpha: 1), dark: UIColor(white: 0.13, alpha: 1))

    // MARK: Ink — semantic labels keep the same hierarchy in both themes.
    static let ink       = Color(uiColor: .label)
    static let inkMuted  = Color(uiColor: .secondaryLabel)
    static let inkFaint  = Color(uiColor: .tertiaryLabel)

    // MARK: Accent — dynamic user-selected theme color
    static var accent: Color {
        ThemeFontManager.shared.accentColor
    }
    static var amber: Color {
        ThemeFontManager.shared.accentColor
    }
    static var ember: Color {
        ThemeFontManager.shared.accentColor
    }
    static var flame: Color {
        ThemeFontManager.shared.flameColor
    }
    /// Favourite / like state, matches the system Music red.
    static var heart: Color {
        ThemeFontManager.shared.heartColor
    }
    /// Positive status (AI online, video-shot on).
    static let positive = Color(hex: "#30D158") ?? .green

    static var emberGradient: LinearGradient {
        ThemeFontManager.shared.emberGradient
    }

    /// Fixed palette for category and genre tiles. Tiles are the one place
    /// where hue carries meaning (books are blue, kids are orange…), so they
    /// pick from this list instead of inventing colours inline.
    enum Tile {
        static let pink    = [Color(hex: "#FF2A85") ?? .pink,   Color(hex: "#FF7300") ?? .orange]
        static let blue    = [Color(hex: "#0088FF") ?? .blue,   Color(hex: "#00E5FF") ?? .cyan]
        static let orange  = [Color(hex: "#FF8A00") ?? .orange, SN.amber]
        static let green   = [SN.positive,                       Color(hex: "#1DE9B6") ?? .teal]
        static let red     = [SN.heart,                          Color(hex: "#FF375F") ?? .red]
        static let brown   = [SN.ember,                          Color(hex: "#7C2D12") ?? .brown]
        static let sand    = [Color(hex: "#FDE68A") ?? .yellow, SN.ember]
        static let crimson = [Color(hex: "#B91C1C") ?? .red,    Color(hex: "#7C2D12") ?? .brown]
        static let gold    = [Color(hex: "#FCD34D") ?? .yellow, Color(hex: "#B45309") ?? .orange]
        static let copper  = [Color(hex: "#FB923C") ?? .orange, Color(hex: "#9A3412") ?? .brown]
        static let graphite = [SN.coal,                          Color(hex: "#3A3A3C") ?? .gray]
    }

    static var hairline: LinearGradient {
        LinearGradient(colors: [ink.opacity(0.22), ink.opacity(0.04), bg.opacity(0.22)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    // MARK: Typography — dynamic user-selected font (Neue Montreal, Satoshi, General Sans, Instrument Sans, PP Neue Machina)
    static func display(_ style: Font.TextStyle = .title2, _ weight: Font.Weight = .bold) -> Font {
        ThemeFontManager.shared.displayFont(style: style, weight: weight)
    }

    static func text(_ style: Font.TextStyle = .body, _ weight: Font.Weight = .regular) -> Font {
        ThemeFontManager.shared.font(style: style, weight: weight)
    }

    static func rounded(_ style: Font.TextStyle = .body, _ weight: Font.Weight = .medium) -> Font {
        ThemeFontManager.shared.roundedFont(style: style, weight: weight)
    }

    static func serifAccent(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .serif, weight: .semibold)
    }

    /// Icon glyph inside a 44pt control; scales with body text.
    static func glyph(_ weight: Font.Weight = .semibold) -> Font {
        .system(.title3, design: .default, weight: weight)
    }

    /// Standard minimum hit target.
    static let tapTarget: CGFloat = 44
}

// MARK: - Settings

enum MusicHapticsIntensity: String, CaseIterable, Identifiable, Codable, Sendable {
    case soft = "soft"
    case medium = "medium"
    case strong = "strong"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: return "Слабая"
        case .medium: return "Средняя"
        case .strong: return "Сильная"
        }
    }

    var scaleFactor: Float {
        switch self {
        case .soft: return 0.45
        case .medium: return 0.75
        case .strong: return 1.00
        }
    }
}

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "settings.haptics") } }
    var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }
    var musicHapticsEnabled: Bool { didSet { defaults.set(musicHapticsEnabled, forKey: "settings.musicHaptics") } }
    var musicHapticsIntensity: MusicHapticsIntensity {
        didSet { defaults.set(musicHapticsIntensity.rawValue, forKey: "settings.musicHapticsIntensity") }
    }

    // Karaoke lyrics & AI alignment
    var lyricsFontSize: Double { didSet { defaults.set(lyricsFontSize, forKey: "lyrics.fontSize") } }
    var lyricsOffset: Double { didSet { defaults.set(lyricsOffset, forKey: "lyrics.offset") } }
    var isNeuralEngineEnabled: Bool { didSet { defaults.set(isNeuralEngineEnabled, forKey: "lyrics.neuralEngineEnabled") } }

    var accentColor: Color { SN.amber }
    var accentGradient: LinearGradient { SN.emberGradient }

    private init() {
        hapticsEnabled = defaults.object(forKey: "settings.haptics") as? Bool ?? true
        scrubHapticsEnabled = defaults.object(forKey: "settings.scrubHaptics") as? Bool ?? true
        musicHapticsEnabled = defaults.object(forKey: "settings.musicHaptics") as? Bool ?? true
        musicHapticsIntensity = MusicHapticsIntensity(
            rawValue: defaults.string(forKey: "settings.musicHapticsIntensity") ?? ""
        ) ?? .strong
        lyricsFontSize = defaults.object(forKey: "lyrics.fontSize") as? Double ?? 46
        lyricsOffset = defaults.object(forKey: "lyrics.offset") as? Double ?? 0
        // Full-track on-device transcription downloads the stream first.
        // Keep it opt-in so ordinary playback never consumes storage silently.
        isNeuralEngineEnabled = defaults.object(forKey: "lyrics.neuralEngineEnabled") as? Bool ?? false
    }
}

// MARK: - Haptics
//
// One entry point so the "Вибрация" toggles in Settings actually gate every
// tap in the app instead of being decorative.

@MainActor
enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard SettingsStore.shared.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func success() {
        guard SettingsStore.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard SettingsStore.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    /// Scrubber ticks are opt-in separately: they fire far more often than taps.
    static func scrubTick(_ generator: UISelectionFeedbackGenerator) {
        guard SettingsStore.shared.hapticsEnabled, SettingsStore.shared.scrubHapticsEnabled else { return }
        generator.selectionChanged()
    }

    /// Тактильный эффект встряхивания и всплеска волны (rigid -> medium -> light).
    static func waveSplash() {
        guard SettingsStore.shared.hapticsEnabled else { return }
        let rigid = UIImpactFeedbackGenerator(style: .rigid)
        rigid.prepare()
        rigid.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - Liquid Glass surfaces
//
// Thin wrappers over the system material so every pill, chip and card in the
// app shares the same glass and picks up lensing, specular highlights and
// interactive press response from the OS instead of a hand-drawn imitation.

extension View {
    /// Rounded-rectangle glass card.
    func glassCard(corner: CGFloat = SN.radius, padding: CGFloat = 0) -> some View {
        self
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: corner))
    }

    /// Glass capsule for pills, badges and toasts.
    func glassCapsule(interactive: Bool = false) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }

    /// Glass circle for 44pt icon controls.
    func glassCircle(interactive: Bool = true) -> some View {
        self.glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
    }

    /// Tinted glass for the one primary action on a screen.
    func glassProminent(_ tint: Color = SN.ember) -> some View {
        self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
    }
}

/// A round 44pt glass icon button — the single shape for every secondary
/// control (close, more, like, wave, video-shot).
struct GlassIconButton: View {
    let systemImage: String
    var tint: Color = SN.ink
    var weight: Font.Weight = .semibold
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(SN.glyph(weight))
                .foregroundStyle(tint)
                .frame(width: SN.tapTarget, height: SN.tapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .accessibilityLabel(accessibilityLabel)
    }
}
