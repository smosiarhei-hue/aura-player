import SwiftUI
import UIKit
import Observation

// MARK: - Sonivo Design System
//
// One source of truth for colour, type, motion and surfaces. Views never
// hard-code hex values or point sizes: they pick a semantic token here so the
// whole app shifts together, scales with Dynamic Type and stays legible on
// every artwork-driven background.

enum AG {
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

    // MARK: Canvas — a deep neutral that lets artwork colour own the screen.
    static let bg       = Color(hex: "#09090B") ?? .black
    static let bgRaised = Color(hex: "#111114") ?? .black
    static let card     = Color(hex: "#18181C") ?? .black
    static let coal     = Color(hex: "#202026") ?? .black

    // MARK: Ink — the app always renders on a dark canvas, so text tokens are
    // fixed white with stepped opacity (matches Apple Music's player).
    static let ink       = Color.white
    static let inkMuted  = Color.white.opacity(0.62)
    static let inkFaint  = Color.white.opacity(0.38)

    // MARK: Accent — a single warm accent; everything else comes from artwork.
    static let amber    = Color(hex: "#FBBF24") ?? .yellow
    static let ember    = Color(hex: "#F97316") ?? .orange
    static let flame    = Color(hex: "#EA580C") ?? .orange
    /// Favourite / like state, matches the system Music red.
    static let heart    = Color(hex: "#FF2D55") ?? .pink
    /// Positive status (AI online, video-shot on).
    static let positive = Color(hex: "#30D158") ?? .green

    static var emberGradient: LinearGradient {
        LinearGradient(colors: [amber, ember, flame], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Fixed palette for category and genre tiles. Tiles are the one place
    /// where hue carries meaning (books are blue, kids are orange…), so they
    /// pick from this list instead of inventing colours inline.
    enum Tile {
        static let pink    = [Color(hex: "#FF2A85") ?? .pink,   Color(hex: "#FF7300") ?? .orange]
        static let blue    = [Color(hex: "#0088FF") ?? .blue,   Color(hex: "#00E5FF") ?? .cyan]
        static let orange  = [Color(hex: "#FF8A00") ?? .orange, AG.amber]
        static let green   = [AG.positive,                       Color(hex: "#1DE9B6") ?? .teal]
        static let red     = [AG.heart,                          Color(hex: "#FF375F") ?? .red]
        static let brown   = [AG.ember,                          Color(hex: "#7C2D12") ?? .brown]
        static let sand    = [Color(hex: "#FDE68A") ?? .yellow, AG.ember]
        static let crimson = [Color(hex: "#B91C1C") ?? .red,    Color(hex: "#7C2D12") ?? .brown]
        static let gold    = [Color(hex: "#FCD34D") ?? .yellow, Color(hex: "#B45309") ?? .orange]
        static let copper  = [Color(hex: "#FB923C") ?? .orange, Color(hex: "#9A3412") ?? .brown]
        static let graphite = [AG.coal,                          Color(hex: "#3A3A3C") ?? .gray]
    }

    static var hairline: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04), Color.black.opacity(0.22)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    // MARK: Typography — every font is a Dynamic Type text style, so sizes
    // follow the user's accessibility setting. Weight and design are the
    // only knobs views may turn.
    static func display(_ style: Font.TextStyle = .title2, _ weight: Font.Weight = .bold) -> Font {
        .system(style, design: .default, weight: weight)
    }

    static func text(_ style: Font.TextStyle = .body, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight)
    }

    static func rounded(_ style: Font.TextStyle = .body, _ weight: Font.Weight = .medium) -> Font {
        .system(style, design: .rounded, weight: weight)
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

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard

    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "settings.haptics") } }
    var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }

    // Karaoke lyrics
    var lyricsFontSize: Double { didSet { defaults.set(lyricsFontSize, forKey: "lyrics.fontSize") } }
    var lyricsOffset: Double { didSet { defaults.set(lyricsOffset, forKey: "lyrics.offset") } }

    var accentColor: Color { AG.amber }
    var accentGradient: LinearGradient { AG.emberGradient }

    private init() {
        hapticsEnabled = defaults.object(forKey: "settings.haptics") as? Bool ?? true
        scrubHapticsEnabled = defaults.object(forKey: "settings.scrubHaptics") as? Bool ?? true
        lyricsFontSize = defaults.object(forKey: "lyrics.fontSize") as? Double ?? 46
        lyricsOffset = defaults.object(forKey: "lyrics.offset") as? Double ?? 0
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

    /// Scrubber ticks are opt-in separately: they fire far more often than taps.
    static func scrubTick(_ generator: UISelectionFeedbackGenerator) {
        guard SettingsStore.shared.hapticsEnabled, SettingsStore.shared.scrubHapticsEnabled else { return }
        generator.selectionChanged()
    }
}

// MARK: - Liquid Glass surfaces
//
// Thin wrappers over the system material so every pill, chip and card in the
// app shares the same glass and picks up lensing, specular highlights and
// interactive press response from the OS instead of a hand-drawn imitation.

extension View {
    /// Rounded-rectangle glass card.
    func glassCard(corner: CGFloat = AG.radius, padding: CGFloat = 0) -> some View {
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
    func glassProminent(_ tint: Color = AG.ember) -> some View {
        self.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
    }
}

/// A round 44pt glass icon button — the single shape for every secondary
/// control (close, more, like, wave, video-shot).
struct GlassIconButton: View {
    let systemImage: String
    var tint: Color = AG.ink
    var weight: Font.Weight = .semibold
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AG.glyph(weight))
                .foregroundStyle(tint)
                .frame(width: AG.tapTarget, height: AG.tapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .accessibilityLabel(accessibilityLabel)
    }
}
