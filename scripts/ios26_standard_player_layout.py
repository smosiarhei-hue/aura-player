from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


def replace_section(text: str, start: str, end: str, replacement: str, label: str) -> str:
    if replacement in text:
        return text
    start_index = text.find(start)
    end_index = text.find(end, start_index + len(start))
    if start_index < 0 or end_index < 0:
        raise RuntimeError(f"{label}: section markers were not found")
    return text[:start_index] + replacement + text[end_index:]


screen = SCREEN.read_text(encoding="utf-8")
screen = replace_required(
    screen,
    '''                        controls
                            .padding(.top, 10)

                        transitionCard
                            .padding(.top, 18)

                        trackWaveCard
                            .padding(.top, 10)

                        featureDock
                            .padding(.top, 18)

''',
    '''''',
    "remove scrolling player controls",
)
screen = replace_required(
    screen,
    '''        .interactiveDismissDisabled(dismissing)
''',
    '''        .interactiveDismissDisabled(dismissing)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBottomGlassBar(
                onLyrics: { showLyrics = true },
                onQueue: { showQueue = true },
                onEqualizer: { showEqualizer = true },
                onSleepTimer: { showSleepTimer = true },
                onTrackWave: startTrackWave,
                onSettings: { showSettings = true }
            )
        }
''',
    "fixed native glass controls",
)
static_cover = '''    private func animatedCover(side: CGFloat) -> some View {
        artwork
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.32), radius: 16, y: 9)
            .id(track?.id)
    }

'''
screen = replace_section(
    screen,
    "    private func animatedCover(side: CGFloat) -> some View {\n",
    "    @ViewBuilder private var artwork: some View {\n",
    static_cover,
    "static efficient artwork",
)
SCREEN.write_text(screen, encoding="utf-8")
print("Fixed native Liquid Glass controls and efficient artwork layout applied.")
