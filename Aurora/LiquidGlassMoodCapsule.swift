import SwiftUI

// MARK: - Mood capsule
//
// One horizontal glass pill per mood: a tinted glass orb with the mood glyph,
// the title, and a chevron. The material, lensing and press response come
// from the system Liquid Glass; only the mood tint is ours.

struct LiquidGlassMoodCapsule: View {
    let preset: MoodPreset
    let action: () -> Void

    private var tint: Color {
        Color(hex: preset.gradientColors.first ?? "") ?? AG.amber
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: preset.iconName)
                    .font(AG.text(.callout, .bold))
                    .foregroundStyle(AG.ink)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.tint(tint.opacity(0.55)), in: .circle)
                    .padding(.leading, 6)

                Text(preset.title.replacingOccurrences(of: "\n", with: " "))
                    .font(AG.rounded(.subheadline, .semibold))
                    .foregroundStyle(AG.ink)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(AG.text(.caption2, .bold))
                    .foregroundStyle(AG.inkMuted)
                    .padding(.trailing, 14)
            }
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
        .accessibilityLabel(preset.title.replacingOccurrences(of: "\n", with: " "))
    }
}
