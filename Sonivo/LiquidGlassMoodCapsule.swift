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
        Color(hex: preset.gradientColors.first ?? "") ?? SN.amber
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: preset.iconName)
                    .font(SN.text(.callout, .bold))
                    .foregroundStyle(SN.ink)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.tint(tint.opacity(0.55)), in: .circle)
                    .padding(.leading, 6)

                Text(preset.title.replacingOccurrences(of: "\n", with: " "))
                    .font(SN.rounded(.subheadline, .semibold))
                    .foregroundStyle(SN.ink)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(SN.text(.caption2, .bold))
                    .foregroundStyle(SN.inkMuted)
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
