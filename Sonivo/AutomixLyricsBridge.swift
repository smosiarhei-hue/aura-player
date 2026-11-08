// Path: Sonivo/AutomixLyricsBridge.swift
//
// Maps Sonivo Lyrics (Yandex LRC / Musixmatch / on-device Speech) into the
// MixPlanner AutomixTranscript used by NeuralAutomixCue.

import Foundation
import MixPlanner

enum AutomixLyricsBridge {
    static func transcript(from lyrics: Lyrics?) -> AutomixTranscript? {
        guard let lyrics, lyrics.isSynchronized else { return nil }
        let source: AutomixTranscriptSource = {
            let name = lyrics.sourceName.lowercased()
            if name.contains("яндекс") || name.contains("yandex") || name.contains("lrc") {
                return .yandexLrc
            }
            if name.contains("whisper") || name.contains("speech") || name.contains("on-device") {
                return .whisper
            }
            return .lyrics
        }()

        let offset = lyrics.offset
        let segments: [AutomixTranscriptSegment] = lyrics.lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, line.startTime.isFinite, offset.isFinite else { return nil }
            let end = line.endTime ?? (line.startTime + 4)
            guard end.isFinite else { return nil }
            let start = max(0, line.startTime + offset)
            let shiftedEnd = max(start, end + offset)
            let words = line.effectiveWords().map {
                AutomixTranscriptWord(
                    text: $0.text,
                    start: $0.startTime + offset,
                    end: $0.endTime + offset
                )
            }
            return AutomixTranscriptSegment(
                text: text,
                start: start,
                end: shiftedEnd,
                words: words
            )
        }
        guard !segments.isEmpty else { return nil }
        return AutomixTranscript(source: source, segments: segments)
    }
}
