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
    let offset: TimeInterval

    static let empty = Lyrics(title: nil, artist: nil, lines: [], isSyllable: false, offset: 0)

    init(title: String? = nil, artist: String? = nil, lines: [LyricsLine], isSyllable: Bool = false, offset: TimeInterval = 0) {
        self.title = title
        self.artist = artist
        self.lines = lines
        self.isSyllable = isSyllable
        self.offset = offset
    }

    /// True when lines carry real timestamps (line- or word-sync); false for plain/static text.
    var isSynchronized: Bool {
        lines.count > 1 && lines.contains { $0.startTime > 0 }
    }
}

// MARK: - High-Precision LRC Parser (line-level + syllable/word-level timestamps + offset)

enum LRCParser {
    // [mm:ss.xx] or [mm:ss.xxx] or [mm:ss:xx] or [mm:ss]
    private static let lineTimeRegex = try? NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#
    )
    private static let wordTimeRegex = try? NSRegularExpression(
        pattern: #"<(\d{1,2}):(\d{1,2}(?:[.:]\d{1,3})?)>"#
    )
    private static let offsetRegex = try? NSRegularExpression(
        pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#,
        options: .caseInsensitive
    )

    static func parse(_ lrc: String) -> Lyrics {
        guard let lineTimeRegex else { return .empty }

        // Extract global offset tag if present (in milliseconds)
        var globalOffsetSeconds: TimeInterval = 0
        if let offsetRegex {
            let nsLrc = lrc as NSString
            let fullRange = NSRange(location: 0, length: nsLrc.length)
            if let match = offsetRegex.firstMatch(in: lrc, range: fullRange),
               let numRange = Range(match.range(at: 1), in: lrc),
               let ms = Double(lrc[numRange]) {
                globalOffsetSeconds = ms / 1000.0
            }
        }

        var lines: [LyricsLine] = []

        for raw in lrc.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Skip metadata tags like [ar:...], [ti:...], [offset:...]
            if trimmed.hasPrefix("[ar:") || trimmed.hasPrefix("[ti:") ||
               trimmed.hasPrefix("[al:") || trimmed.hasPrefix("[by:") ||
               trimmed.hasPrefix("[offset:") || trimmed.hasPrefix("[re:") ||
               trimmed.hasPrefix("[ve:") {
                continue
            }

            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            let timeMatches = lineTimeRegex.matches(in: raw, range: range)
            guard !timeMatches.isEmpty else { continue }

            let content = lineTimeRegex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
            let parsed = parseContent(content, globalOffset: globalOffsetSeconds)
            guard !parsed.text.isEmpty else { continue }

            for match in timeMatches {
                guard let minR = Range(match.range(at: 1), in: raw),
                      let secR = Range(match.range(at: 2), in: raw) else { continue }
                let minutes = Double(raw[minR]) ?? 0
                let secStr = String(raw[secR]).replacingOccurrences(of: ":", with: ".")
                let seconds = Double(secStr) ?? 0
                let rawTime = minutes * 60.0 + seconds
                let time = max(0, rawTime - globalOffsetSeconds)

                lines.append(LyricsLine(text: parsed.text, startTime: time, endTime: nil, words: parsed.words))
            }
        }

        guard !lines.isEmpty else { return .empty }

        lines.sort { $0.startTime < $1.startTime }

        // Compute intelligent endTime for each line
        for i in lines.indices {
            let current = lines[i]
            let charCount = max(current.text.count, 5)
            // Estimated sung duration based on natural singing rate (~11 chars/sec + padding)
            let estimatedSingDuration = Double(charCount) * 0.11 + 1.2

            if i + 1 < lines.count {
                let nextStart = lines[i + 1].startTime
                let gap = nextStart - current.startTime
                if gap <= 5.5 {
                    lines[i].endTime = nextStart
                } else {
                    // Instrumental break / pause between verses: fade line out after singing
                    lines[i].endTime = min(nextStart, current.startTime + max(estimatedSingDuration, 3.2))
                }
            } else {
                lines[i].endTime = current.startTime + max(estimatedSingDuration, 4.0)
            }
        }

        let isSyllable = lines.contains { ($0.words?.count ?? 0) > 1 }
        return Lyrics(title: nil, artist: nil, lines: lines, isSyllable: isSyllable, offset: globalOffsetSeconds)
    }

    private static func parseContent(_ content: String, globalOffset: TimeInterval) -> (text: String, words: [LyricsWord]?) {
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

            let start = max(0, timestamp(from: content, match: match) - globalOffset)
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
            let end = (i + 1 < filtered.count) ? filtered[i + 1].startTime : (w.startTime + 2.0)
            return LyricsWord(text: w.text, startTime: w.startTime, endTime: max(end, w.startTime + 0.1))
        }

        return (plain.trimmingCharacters(in: .whitespacesAndNewlines), fixed)
    }

    private static func timestamp(from text: String, match: NSTextCheckingResult) -> TimeInterval {
        guard let minR = Range(match.range(at: 1), in: text),
              let secR = Range(match.range(at: 2), in: text) else { return 0 }
        let minutes = Double(text[minR]) ?? 0
        let secStr = String(text[secR]).replacingOccurrences(of: ":", with: ".")
        let seconds = Double(secStr) ?? 0
        return minutes * 60.0 + seconds
    }
}
