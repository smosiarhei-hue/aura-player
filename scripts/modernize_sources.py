from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AURORA = ROOT / "Aurora"

OBSERVABLE_FILES = {
    "playercore.swift": "PlayerCore",
    "librarystore.swift": "LibraryStore",
    "theme.swift": "SettingsStore",
    "yandexmusicservice.swift": "YandexMusicService",
    "socialauth.swift": "SocialAuthStore",
    "lyricsservice.swift": "LyricsService",
}

for path in AURORA.glob("*.swift"):
    text = path.read_text()
    text = text.replace("@StateObject private var", "@State private var")
    text = text.replace("@ObservedObject private var", "@Bindable private var")

    if path.name in OBSERVABLE_FILES:
        name = OBSERVABLE_FILES[path.name]
        text = text.replace("import Combine\n", "")
        if "import Observation\n" not in text:
            imports = [line for line in text.splitlines() if line.startswith("import ")]
            if imports:
                anchor = imports[-1] + "\n"
                text = text.replace(anchor, anchor + "import Observation\n", 1)
        text = text.replace(
            f"final class {name}: ObservableObject {{",
            f"@Observable\n@MainActor\nfinal class {name} {{",
            1,
        )
        text = text.replace("@Published ", "")

    path.write_text(text)

# Immutable/domain models used across async boundaries.
sendable_replacements = {
    "enum TransitionMode: String, CaseIterable, Codable, Identifiable {":
        "enum TransitionMode: String, CaseIterable, Codable, Identifiable, Sendable {",
    "enum AutoMixStyle {": "enum AutoMixStyle: Sendable {",
    "struct Track: Identifiable, Codable, Equatable {":
        "struct Track: Identifiable, Codable, Equatable, Sendable {",
    "struct Playlist: Identifiable, Codable, Equatable {":
        "struct Playlist: Identifiable, Codable, Equatable, Sendable {",
    "enum RepeatMode: Int, Codable, CaseIterable {":
        "enum RepeatMode: Int, Codable, CaseIterable, Sendable {",
    "struct EQPreset: Identifiable, Equatable {":
        "struct EQPreset: Identifiable, Equatable, Sendable {",
    "struct LyricsWord: Equatable {": "struct LyricsWord: Equatable, Sendable {",
    "struct LyricsLine: Equatable, Identifiable {":
        "struct LyricsLine: Equatable, Identifiable, Sendable {",
    "struct Lyrics: Equatable {": "struct Lyrics: Equatable, Sendable {",
}

for filename in ("models.swift", "lyricsmodel.swift"):
    path = AURORA / filename
    text = path.read_text()
    for old, new in sendable_replacements.items():
        text = text.replace(old, new)
    path.write_text(text)

# Modern two-argument onChange closure.
path = AURORA / "searchviews.swift"
text = path.read_text().replace(
    ".onChange(of: searchText) { newValue in",
    ".onChange(of: searchText) { _, newValue in",
)
path.write_text(text)

# The previous fullscreen implementation is no longer referenced; do not compile
# duplicate legacy UIKit/deprecated paths while the replacement is active.
project = ROOT / "project.yml"
text = project.read_text()
if '- "PlayerScreen.swift"' not in text:
    text = text.replace('- "Info.plist"', '- "Info.plist"\n          - "PlayerScreen.swift"')
project.write_text(text)
