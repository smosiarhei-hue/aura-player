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
        text = text.replace("@MainActor\n@Observable\n@MainActor", "@Observable\n@MainActor")
        text = text.replace("@Observable\n@MainActor\n@MainActor", "@Observable\n@MainActor")

    path.write_text(text)

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

path = AURORA / "searchviews.swift"
text = path.read_text().replace(
    ".onChange(of: searchText) { newValue in",
    ".onChange(of: searchText) { _, newValue in",
)
path.write_text(text)

player = AURORA / "playercore.swift"
text = player.read_text()
text = text.replace(
'''                self.playerA.scheduleSegment(audioFile, startingFrame: validOffset, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            guard let self, self.generation == token, !self.isUsingStreamPlayer else { return }
                            self.handleTrackFinish()
                        }
                    }
                }''',
'''                self.playerA.scheduleSegment(audioFile, startingFrame: validOffset, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token, !self.isUsingStreamPlayer else { return }
                        self.handleTrackFinish()
                    }
                }'''
)
text = text.replace(
'''            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self, self.generation == token else { return }
                self.isTransitioning = false
                self.currentTrack = nextTrack
                self.start(at: 0) // transitionScheduled cleared in beginStream
            }''',
'''            Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) }
                catch { return }
                guard let self, self.generation == token else { return }
                self.isTransitioning = false
                self.currentTrack = nextTrack
                self.start(at: 0)
            }'''
)
text = text.replace(
'''                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        Task { @MainActor in
                            guard let self, self.activePlayer === targetIdlePlayer else { return }
                            self.handleTrackFinish()
                        }
                    }
                }''',
'''                targetIdlePlayer.scheduleSegment(nextFile, startingFrame: 0, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.activePlayer === targetIdlePlayer else { return }
                        self.handleTrackFinish()
                    }
                }'''
)
text = text.replace(
    "SpectrumAnalyzer.shared.process(buffer: buffer, sampleRate: buffer.format.sampleRate)",
    "SpectrumAnalyzer.ingest(buffer: buffer, sampleRate: buffer.format.sampleRate)"
)
player.write_text(text)

stream = AURORA / "streambeat.swift"
text = stream.read_text().replace(
    "SpectrumAnalyzer.shared.feedStreamLevel(acc / Float(count))",
    "SpectrumAnalyzer.ingestStreamLevel(acc / Float(count))"
)
stream.write_text(text)

project = ROOT / "project.yml"
text = project.read_text()
if '- "PlayerScreen.swift"' not in text:
    text = text.replace('- "Info.plist"', '- "Info.plist"\n          - "PlayerScreen.swift"')
project.write_text(text)
