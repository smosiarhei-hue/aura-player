import Foundation

// MARK: - Synchronized Lyrics Model (Karaoke)

nonisolated struct LyricsWord: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

nonisolated struct LyricsLine: Equatable, Identifiable, Sendable {
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

nonisolated struct Lyrics: Equatable, Sendable {
    let title: String?
    let artist: String?
    let lines: [LyricsLine]
    let isSyllable: Bool
    let offset: TimeInterval
    let sourceName: String

    static let empty = Lyrics(title: nil, artist: nil, lines: [], isSyllable: false, offset: 0, sourceName: "")

    init(
        title: String? = nil,
        artist: String? = nil,
        lines: [LyricsLine],
        isSyllable: Bool = false,
        offset: TimeInterval = 0,
        sourceName: String = "Яндекс Музыка"
    ) {
        self.title = title
        self.artist = artist
        self.lines = lines
        self.isSyllable = isSyllable
        self.offset = offset
        self.sourceName = sourceName
    }

    /// True when lines carry real timestamps (line- or word-sync); false for plain/static text.
    var isSynchronized: Bool {
        !lines.isEmpty && lines.contains { ($0.startTime.isFinite && $0.startTime > 0) || $0.hasRealWordTimings }
    }
}

// MARK: - Word Timing Verification

extension LyricsLine {
    /// True only if genuine word-by-word/syllable timestamps are present from source.
    nonisolated var hasRealWordTimings: Bool {
        guard let words, !words.isEmpty else { return false }
        guard words.allSatisfy({ $0.startTime.isFinite && $0.endTime.isFinite
            && $0.startTime >= 0 && $0.endTime > $0.startTime }) else { return false }
        return zip(words, words.dropFirst()).allSatisfy { pair in pair.1.startTime > pair.0.startTime }
    }

    /// Returns explicit words if present from source.
    /// Does NOT synthesize fake word timings for standard line-synced lyrics.
    nonisolated func effectiveWords() -> [LyricsWord] {
        if hasRealWordTimings, let words {
            return words
        }
        return []
    }
}

extension Lyrics {
    /// True only if actual syllable/word-level timestamps exist.
    nonisolated var hasDynamicWordTimings: Bool {
        isSyllable && lines.contains { $0.hasRealWordTimings }
    }
}

// MARK: - High-Precision LRC Parser (line-level + syllable/word-level timestamps + offset)

nonisolated enum LRCParser {
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

    static func parse(_ lrc: String, sourceName: String = "Яндекс Музыка") -> Lyrics {
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
            let firstLineStart = timeMatches.first.map { timestamp(from: raw, match: $0) } ?? 0
            let parsed = parseContent(content, lineStart: firstLineStart, globalOffset: globalOffsetSeconds)
            let cleanText = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            // Filter out empty instrumental markers that create gaps in text
            if cleanText == "//" || cleanText == "---" || cleanText == "..." || cleanText == "♪" {
                continue
            }

            for match in timeMatches {
                guard let minR = Range(match.range(at: 1), in: raw),
                      let secR = Range(match.range(at: 2), in: raw) else { continue }
                let minutes = Double(raw[minR]) ?? 0
                let secStr = String(raw[secR]).replacingOccurrences(of: ":", with: ".")
                let seconds = Double(secStr) ?? 0
                let rawTime = minutes * 60.0 + seconds
                let time = max(0, rawTime - globalOffsetSeconds)

                // Repeated [line] tags reuse the same enhanced text. Shift genuine
                // absolute word timestamps by this occurrence's source delta only.
                let delta = rawTime - firstLineStart
                let words = delta == 0 ? parsed.words : parseContent(content, lineStart: firstLineStart,
                    globalOffset: globalOffsetSeconds, occurrenceShift: delta).words
                let sourceStart = min(time, words?.first?.startTime ?? time)
                lines.append(LyricsLine(text: cleanText, startTime: sourceStart, endTime: nil, words: words))
            }
        }

        guard !lines.isEmpty else { return .empty }

        lines.sort { $0.startTime < $1.startTime }

        // Compute contiguous endTime for each line (continuous flow without voids)
        for i in lines.indices {
            if i + 1 < lines.count {
                lines[i].endTime = lines[i + 1].startTime
            } else {
                lines[i].endTime = lines[i].startTime + 8.0
            }
        }

        let isSyllable = lines.contains { $0.hasRealWordTimings }
        return Lyrics(title: nil, artist: nil, lines: lines, isSyllable: isSyllable, offset: globalOffsetSeconds, sourceName: sourceName)
    }

    private static func parseContent(_ content: String, lineStart: Double,
                                     globalOffset: TimeInterval, occurrenceShift: Double = 0) -> (text: String, words: [LyricsWord]?) {
        guard let wordTimeRegex else { return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        let ns = content as NSString
        let matches = wordTimeRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (content.trimmingCharacters(in: .whitespacesAndNewlines), nil) }
        var fragments: [LyricsWord] = []
        let leading = ns.substring(to: matches[0].range.location)
        var plain = leading
        if !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fragments.append(LyricsWord(text: leading, startTime: max(0, lineStart + occurrenceShift - globalOffset),
                endTime: max(0, timestamp(from: content, match: matches[0]) + occurrenceShift - globalOffset)))
        }
        for (index, match) in matches.enumerated() {
            let begin = match.range.location + match.range.length
            let finish = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: begin, length: max(0, finish - begin)))
            plain += text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = max(0, timestamp(from: content, match: match) + occurrenceShift - globalOffset)
            // An empty terminal tag is a real end boundary, not another word.
            let end = index + 1 < matches.count
                ? max(0, timestamp(from: content, match: matches[index + 1]) + occurrenceShift - globalOffset)
                : start + 2
            fragments.append(LyricsWord(text: text, startTime: start, endTime: end))
        }
        let clean = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, mergeSourceFragments(fragments, text: clean))
    }

    /// Enhanced LRC may time syllables rather than words. Preserve the first real
    /// syllable onset of each displayed word; never distribute time over letters.
    private static func mergeSourceFragments(_ fragments: [LyricsWord], text: String) -> [LyricsWord]? {
        guard !fragments.isEmpty, fragments.allSatisfy({ $0.startTime.isFinite && $0.endTime.isFinite
            && $0.startTime >= 0 && $0.endTime > $0.startTime }) else { return nil }
        let actual = fragments.flatMap { fragment in
            fragment.text.filter { !$0.isWhitespace }.map {
                (character: $0, start: fragment.startTime, end: fragment.endTime)
            }
        }
        guard actual.map(\.character) == Array(text.filter { !$0.isWhitespace }) else { return nil }
        var cursor = 0
        var words: [LyricsWord] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let count = token.count
            guard count > 0, cursor + count <= actual.count else { return nil }
            words.append(LyricsWord(text: String(token), startTime: actual[cursor].start,
                endTime: actual[cursor + count - 1].end))
            cursor += count
        }
        let line = LyricsLine(text: text, startTime: 0, words: words)
        return cursor == actual.count && line.hasRealWordTimings ? words : nil
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
