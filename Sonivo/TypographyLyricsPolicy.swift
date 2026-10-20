import Foundation

/// Source timestamps only. Visual animation never creates a vocal timing.
nonisolated enum TypographyLyricsPolicy {
    static func activeIndex(lines: [LyricsLine], synchronized: Bool,
                            time: Double, duration: Double) -> Int? {
        guard synchronized, time.isFinite, time >= 0 else { return nil }
        guard let index = lines.indices.last(where: {
            lines[$0].startTime.isFinite && lines[$0].startTime >= 0 && lines[$0].startTime <= time
        }) else { return nil }
        // Retain this row until the next starts, as in classic Lines. Explicit
        // word/line ends still bound the word sweep, not the scroll selection.
        if duration.isFinite, duration > 0, time >= duration { return nil }
        return index
    }

    static func segments(_ text: String) -> [String] {
        var result: [String] = []
        var part = ""
        var wasSpace = false
        for character in text {
            if !character.isWhitespace && wasSpace && !part.isEmpty {
                result.append(part)
                part = ""
            }
            part.append(character)
            wasSpace = character.isWhitespace
        }
        if !part.isEmpty { result.append(part) }
        return result
    }

    static func matchedWords(for line: LyricsLine) -> [LyricsWord]? {
        guard line.hasRealWordTimings, let words = line.words else { return nil }
        let tokens = segments(line.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard tokens == words.map({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return nil }
        return words
    }
}

nonisolated enum LyricsControlsPolicy {
    static let idleSeconds: Double = 10
    static func shouldAutoHide(isPlaying: Bool, isBuffering: Bool, visible: Bool,
                               lyricsVisible: Bool, sceneActive: Bool, voiceOver: Bool) -> Bool {
        isPlaying && !isBuffering && visible && lyricsVisible && sceneActive && !voiceOver
    }
}
