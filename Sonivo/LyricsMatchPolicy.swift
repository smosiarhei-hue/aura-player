import Foundation
import AVFoundation

/// Conservative source identity: never select an unrelated first search result.
nonisolated enum LyricsMatchPolicy {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func canonicalTitle(_ title: String) -> String {
        // Only harmless metadata is removed. Slowed/sped-up/live/remix stay in identity.
        let clean = title
            .replacingOccurrences(of: #"(?i)[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)[\(\[]\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*[\)\]]"#, with: "", options: .regularExpression)
        return normalized(clean)
    }

    static func knownArtist(_ value: String) -> Bool {
        !["", "unknown", "unknown artist", "неизвестный исполнитель", "неизвестен"].contains(normalized(value))
    }

    static func principalArtist(_ value: String) -> String {
        let first = value.components(separatedBy: ",").first ?? value
        let clean = first.replacingOccurrences(of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$"#, with: "", options: .regularExpression)
        return normalized(clean)
    }

    static func matches(title: String, artist: String, candidateTitle: String?, candidateArtist: String?) -> Bool {
        guard knownArtist(artist), let candidateTitle, let candidateArtist,
              knownArtist(candidateArtist), !canonicalTitle(title).isEmpty else { return false }
        return canonicalTitle(title) == canonicalTitle(candidateTitle)
            && principalArtist(artist) == principalArtist(candidateArtist)
    }

    static func durationMatches(_ expected: Double, _ candidate: Double?) -> Bool {
        guard expected.isFinite, expected > 0 else { return true }
        guard let candidate, candidate.isFinite, candidate > 0 else { return false }
        return abs(expected - candidate) <= max(2, min(5, expected * 0.015))
    }

    static func recordingTitle(_ title: String, version: String?) -> String {
        guard let version, !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        let token = normalized(version)
        if (" " + normalized(title) + " ").contains(" " + token + " ") { return title }
        return "\(title) (\(version))"
    }

    static func yandexID(fileName: String) -> String? {
        // A filename containing random digits or a UUID is NOT a Yandex track ID.
        guard fileName.hasPrefix("ym_"), fileName.hasSuffix(".mp3") else { return nil }
        let raw = String(fileName.dropFirst(3).dropLast(4))
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return String(parts[0]) // track:album, not the album component
    }

    static func plain(_ lyrics: Lyrics) -> Lyrics {
        Lyrics(title: lyrics.title, artist: lyrics.artist,
            lines: lyrics.lines.map { LyricsLine(text: $0.text, startTime: 0) },
            isSyllable: false, sourceName: lyrics.sourceName)
    }

    static func validatedTimings(_ lyrics: Lyrics, duration: Double) -> Lyrics {
        guard lyrics.isSynchronized else { return lyrics }
        let starts = lyrics.lines.map(\.startTime)
        guard starts.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(starts, starts.dropFirst()).allSatisfy({ pair in pair.0 <= pair.1 }),
              duration <= 0 || starts.allSatisfy({ $0 < duration + 1 }) else { return plain(lyrics) }
        var lines: [LyricsLine] = []
        for (index, line) in lyrics.lines.enumerated() {
            let next = index + 1 < lyrics.lines.count ? lyrics.lines[index + 1].startTime : nil
            var end = line.endTime ?? next ?? (line.startTime + 4)
            if let next, next > line.startTime { end = min(end, next) }
            if duration > line.startTime { end = min(end, duration) }
            guard end.isFinite, end > line.startTime else { return plain(lyrics) }
            let words: [LyricsWord]? = line.hasRealWordTimings ? line.words?.compactMap { word in
                guard word.startTime >= line.startTime - 0.1, word.startTime < end else { return nil }
                return LyricsWord(text: word.text, startTime: word.startTime, endTime: min(word.endTime, end))
            } : nil
            // Keep the complete line text if any malformed word fragment was dropped.
            let completeWords = words?.count == line.words?.count ? words : nil
            lines.append(LyricsLine(text: line.text, startTime: line.startTime, endTime: end, words: completeWords))
        }
        return Lyrics(title: lyrics.title, artist: lyrics.artist, lines: lines,
                      isSyllable: lines.contains { $0.hasRealWordTimings }, offset: lyrics.offset, sourceName: lyrics.sourceName)
    }

    static func isLegacyEstimatedLRC(_ lyrics: Lyrics, duration: Double) -> Bool {
        guard lyrics.lines.count >= 3, !lyrics.hasDynamicWordTimings else { return false }
        let total = duration > 10 ? duration : 180
        let interval = max(1.8, (total - 6) / Double(lyrics.lines.count))
        return lyrics.lines.enumerated().allSatisfy { index, line in
            abs(line.startTime - (Double(index) * interval + 1)) < 0.03
        }
    }

    static func agreesWithOfficialText(_ candidate: Lyrics, official: Lyrics?) -> Bool {
        guard let official else { return true }
        let reference = normalized(official.lines.map(\.text).joined(separator: " ")).split(separator: " ").map(String.init)
        let actual = normalized(candidate.lines.map(\.text).joined(separator: " ")).split(separator: " ").map(String.init)
        guard reference.count >= 8 else { return true }
        // Compare contiguous phrases, not loose common words like 'you' or 'love'.
        let window = 5
        let candidatePhrases = Set((0...max(0, actual.count - window)).map { actual.dropFirst($0).prefix(window).joined(separator: " ") })
        let phrases = (0...(reference.count - window)).map { reference.dropFirst($0).prefix(window).joined(separator: " ") }
        return Double(phrases.filter { candidatePhrases.contains($0) }.count) / Double(phrases.count) >= 0.70
    }
}

/// AVPlayer's presentation time is already its playback clock. Do not subtract
/// Bluetooth output latency a second time; native audio-engine render time needs it.
@MainActor
enum LyricsPlaybackClock {
    static func routeLatency(for player: ActivePlayerPresentation) -> Double {
        player.usesStreamingBackend ? 0 : AVAudioSession.sharedInstance().outputLatency
    }
    static func time(for player: ActivePlayerPresentation, offset: Double) -> Double {
        max(0, player.progress - routeLatency(for: player) + offset)
    }
    static func seekTime(lineStart: Double, player: ActivePlayerPresentation, offset: Double) -> Double {
        max(0, lineStart - offset + routeLatency(for: player))
    }
}
