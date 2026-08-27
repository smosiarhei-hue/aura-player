import Foundation

// MARK: - Synchronized Lyrics Model (Karaoke)

struct LyricsWord: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct LyricsLine: Equatable, Identifiable, Sendable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval
    var endTime: TimeInterval?
    let words: [LyricsWord]?

    init(text: String, startTime: TimeInterval, endTime: TimeInterval? = nil, words: [LyricsWord]? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
    }
}

struct Lyrics: Equatable, Sendable {
    let title: String?
    let artist: String?
    let lines: [LyricsLine]
    let isSyllable: Bool

    static let empty = Lyrics(title: nil, artist: nil, lines: [], isSyllable: false)

    /// True when lines carry real timestamps (line- or word-sync); false for plain/static text.
    var isSynchronized: Bool {
        lines.count > 1 && lines.contains { $0.startTime > 0 }
    }
}

// MARK: - LRC Parser (line-level + enhanced word-level timestamps)

enum LRCParser {
    // [mm:ss.cc] for lines, <mm:ss.cc> for word-sync inside a line.
    private static let lineTimeRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#
    )
    private static let wordTimeRegex = try? NSRegularExpression(
        pattern: #"<(\d{1,2}):(\d{1,2}(?:[.:]\d{1,3})?)>"#
    )

    static func parse(_ lrc: String) -> Lyrics {
        guard let lineTimeRegex else { return .empty }
        var lines: [LyricsLine] = []

        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let timeMatches = lineTimeRegex.matches(in: raw, range: range)
            guard !timeMatches.isEmpty else { continue }

            let content = lineTimeRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
            let parsed = parseContent(content)

            for match in timeMatches {
                guard let minR = Range(match.range(at: 1), in: raw),
                      let secR = Range(match.range(at: 2), in: raw) else { continue }
                let minutes = Double(raw[minR]) ?? 0
                let secStr = String(raw[secR]).replacingOccurrences(of: ",", with: ".")
                let seconds = Double(secStr) ?? 0
                let time = minutes * 60 + seconds
                lines.append(LyricsLine(text: parsed.text, startTime: time, endTime: nil, words: parsed.words))
            }
        }

        lines.sort { $0.startTime < $1.startTime }
        for i in lines.indices {
            lines[i].endTime = (i + 1 < lines.count) ? lines[i + 1].startTime : lines[i].startTime + 5
        }

        let isSyllable = lines.contains { ($0.words?.count ?? 0) > 1 }
        return Lyrics(title: nil, artist: nil, lines: lines, isSyllable: isSyllable)
    }

    private static func parseContent(_ content: String) -> (text: String, words: [LyricsWord]?) {
        guard let wordTimeRegex else { return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = wordTimeRegex.matches(in: content, range: range)
        guard !matches.isEmpty else {
            return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        var words: [LyricsWord] = []
        var plain = ""
        var cursor = 0

        for match in matches {
            let textRange = NSRange(location: cursor, length: match.range.location - cursor)
            let wordText = ns.substring(with: textRange)
            if !wordText.isEmpty {
                plain += wordText
            }

            let start = timestamp(from: content, match: match)
            words.append(LyricsWord(text: wordText, startTime: start, endTime: start))
            cursor = match.range.location + match.range.length
        }

        let trailing = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
        plain += trailing

        let filtered = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !filtered.isEmpty else {
            return (plain.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let fixed: [LyricsWord] = filtered.enumerated().map { i, w in
            let end = (i + 1 < filtered.count) ? filtered[i + 1].startTime : (w.startTime + 2)
            return LyricsWord(text: w.text, startTime: w.startTime, endTime: end)
        }
        return (plain.trimmingCharacters(in: .whitespacesAndNewlines), fixed)
    }

    private static func timestamp(from text: String, match: NSTextCheckingResult) -> TimeInterval {
        guard let minR = Range(match.range(at: 1), in: text),
              let secR = Range(match.range(at: 2), in: text) else { return 0 }
        let minutes = Double(text[minR]) ?? 0
        let secStr = String(text[secR]).replacingOccurrences(of: ",", with: ".")
        let seconds = Double(secStr) ?? 0
        return minutes * 60 + seconds
    }
}
