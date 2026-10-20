import Foundation

/// Source timestamps only. Visual animation never creates a vocal timing.
nonisolated enum TypographyLyricsPolicy {
    static func activeIndex(lines: [LyricsLine], synchronized: Bool,
                            time: Double, duration: Double) -> Int? {
        guard synchronized, time.isFinite, time >= 0 else { return nil }
        guard let index = lines.indices.last(where: {
            lines[$0].startTime.isFinite && lines[$0].startTime >= 0 && lines[$0].startTime <= time
        }) else { return nil }
        let line = lines[index]
        let next = lines.dropFirst(index + 1).first(where: {
            $0.startTime.isFinite && $0.startTime > line.startTime
        })?.startTime
        let end: Double
        if let explicit = line.endTime, explicit.isFinite, explicit > line.startTime {
            end = min(explicit, next ?? explicit)
        } else {
            end = next ?? (duration.isFinite && duration > line.startTime ? duration : line.startTime + 12)
        }
        return time < end ? index : nil
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
