import SwiftUI

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

    // MARK: - Typography
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func serifAccent(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }
}

// MARK: - Ember Backdrop (warm glow on near-black canvas)

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

// MARK: - Small reusable Ember controls

struct EmberSectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var size: CGFloat = 22
