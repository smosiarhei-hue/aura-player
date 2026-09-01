"""Show the transition the planner actually chose in the player toast.

Stage 5 of the AutoMix work. The toast printed the configured DJ style, which
is a setting, not what happens at the junction: the same label appeared whether
the tracks got a 16 bar beat matched blend or a 3 second crossfade fallback.
AutoMixController knows the chosen scenario, its bar count and the tempo
correction, so the toast shows that and keeps the old text as a fallback for
streams and for junctions where the analysis was not ready in time.

This lives in a patch script rather than in the source file because
PlayerScreenV2.swift is also rewritten by player_ux_fixes.py during the build.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"


def replace_once(text, old, new, label):
    if new in text:
        return text
    found = text.count(old)
    if found != 1:
        raise RuntimeError(
            label + ": expected exactly one source anchor, found " + str(found)
        )
    return text.replace(old, new, 1)


screen = SCREEN.read_text(encoding="utf-8")

# 1. Observe the controller so the toast updates as the plan appears.
screen = replace_once(
    screen,
    r'''    @State private var dj = AutoMixDJEngine.shared
''',
    r'''    @State private var dj = AutoMixDJEngine.shared
    @State private var automix = AutoMixController.shared
''',
    "automix badge state",
)

# 2. Report the real plan: "AutoMix - 16 tactov - tempo +2.4 %".
screen = replace_once(
    screen,
    r'''                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AG.amber)
                            Text("AutoMix DJ: \(dj.activeStyle.localizedTitle)")
''',
    r'''                            Image(systemName: automix.isBeatMatched ? "metronome.fill" : "sparkles")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AG.amber)
                            Text(automix.badge ?? "AutoMix DJ: \(dj.activeStyle.localizedTitle)")
''',
    "automix badge toast",
)

SCREEN.write_text(screen, encoding="utf-8")
print("AutoMix plan badge wired into the player toast.")
