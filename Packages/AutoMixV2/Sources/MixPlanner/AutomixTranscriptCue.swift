// Path: Packages/AutoMixV2/Sources/MixPlanner/AutomixTranscriptCue.swift
//
// Timed lyrics / Whisper-style transcript → Automix mixOut / mixIn hints.
// Mirrors tools/automix-lab/src/audio/transcriptCues.ts so iOS Sonivo and the
// lab share the same phrase-end logic (not a fixed N-second crossfade).

import Foundation

public struct AutomixTranscriptWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct AutomixTranscriptSegment: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public let words: [AutomixTranscriptWord]

    public init(text: String, start: Double, end: Double, words: [AutomixTranscriptWord] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

public enum AutomixTranscriptSource: String, Sendable, Equatable {
    case whisper
    case yandexLrc
    case lyrics
    case none
}

public struct AutomixTranscript: Sendable, Equatable {
    public let source: AutomixTranscriptSource
    public let segments: [AutomixTranscriptSegment]

    public init(source: AutomixTranscriptSource, segments: [AutomixTranscriptSegment]) {
        self.source = source
        self.segments = segments
    }
}

public struct CueFromTranscript: Sendable, Equatable {
    public let mixOutSec: Double?
    public let mixInSec: Double?
    public let reason: String
    public let confidence: Double

    public init(mixOutSec: Double?, mixInSec: Double?, reason: String, confidence: Double) {
        self.mixOutSec = mixOutSec
        self.mixInSec = mixInSec
        self.reason = reason
        self.confidence = confidence
    }
}

public enum AutomixTranscriptCue {
    /// Shared Automix outro window — keep neural + planner aligned.
    public static func outroWindow(durationSec: Double, minTailSec: Double = 24) -> (earliest: Double, latest: Double) {
        let latest = max(durationSec * 0.7, durationSec - minTailSec)
        let earliest = min(latest, durationSec * 0.58)
        return (earliest, latest)
    }

    /// Best mix-out: last solid vocal phrase end that still leaves mashup tail.
    public static func cue(
        from transcript: AutomixTranscript,
        durationSec: Double,
        minTailSec: Double = 24
    ) -> CueFromTranscript {
        let words = allWords(transcript)
        let segs = transcript.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        guard (!words.isEmpty || !segs.isEmpty), durationSec >= 40 else {
            return CueFromTranscript(mixOutSec: nil, mixInSec: nil, reason: "no transcript words", confidence: 0)
        }

        let window = outroWindow(durationSec: durationSec, minTailSec: minTailSec)
        let isLrc = transcript.source == .yandexLrc
        let label: String = {
            switch transcript.source {
            case .yandexLrc: return "LRC"
            case .whisper: return "Whisper"
            case .lyrics: return "Текст"
            case .none: return "Текст"
            }
        }()

        var best: (at: Double, score: Double, idx: Int, kind: String)?

        for (i, s) in segs.enumerated() {
            if s.end < window.earliest || s.end > window.latest { continue }
            let next = i + 1 < segs.count ? segs[i + 1] : nil
            let gap = next.map { max(0, $0.start - s.end) } ?? 2.5
            let minGap = isLrc ? 0.15 : 0.55
            if next != nil, gap < minGap { continue }
            let room = (window.latest - s.end) / max(1, minTailSec)
            let score = min(4, max(gap, isLrc ? 1.1 : gap)) * 2.2
                + min(1.5, room)
                + (isLrc ? 0.8 : 0)
            if best == nil || score > best!.score {
                best = (s.end, score, i, "line")
            }
        }

        if !isLrc {
            for i in 0..<max(0, words.count - 1) {
                let a = words[i]
                let b = words[i + 1]
                if a.end < window.earliest || a.end > window.latest { continue }
                let gap = b.start - a.end
                if gap < 0.9 { continue }
                let room = (window.latest - a.end) / max(1, minTailSec)
                let score = min(4, gap) * 2 + min(1.5, room)
                if best == nil || score > best!.score {
                    best = (a.end, score, i, "gap")
                }
            }
        }

        if best == nil {
            for i in stride(from: segs.count - 1, through: 0, by: -1) {
                let s = segs[i]
                if s.end >= window.earliest, s.end <= window.latest {
                    best = (s.end, 1, i, "last-line")
                    break
                }
            }
        }
        if best == nil {
            for i in stride(from: words.count - 1, through: 0, by: -1) {
                let w = words[i]
                if w.end >= window.earliest, w.end <= window.latest {
                    best = (w.end, 1, i, "last-word")
                    break
                }
            }
        }

        var mixIn: Double?
        let introLimit = min(48, durationSec * 0.3)
        for (i, s) in segs.enumerated() {
            if s.start > introLimit { break }
            if s.start < 3.5 { continue }
            let prev = i > 0 ? segs[i - 1] : nil
            let gap = prev.map { s.start - $0.end } ?? s.start
            if gap >= 0.45 || s.start >= 6 {
                mixIn = max(0, s.start - 0.12)
                break
            }
        }
        if mixIn == nil {
            for i in 0..<words.count {
                let w = words[i]
                if w.start > introLimit { break }
                let next = i + 1 < words.count ? words[i + 1] : nil
                if w.start >= 4, let next, next.start - w.end < 0.8 {
                    mixIn = max(0, w.start - 0.15)
                    break
                }
            }
        }

        guard let best else {
            return CueFromTranscript(
                mixOutSec: nil,
                mixInSec: mixIn,
                reason: "transcript has no usable outro phrase",
                confidence: mixIn != nil ? 0.35 : 0
            )
        }

        let confidence: Double =
            best.score >= 4 ? 0.9
            : best.score >= 2.5 ? 0.78
            : best.kind.hasPrefix("last") ? 0.55
            : 0.68

        return CueFromTranscript(
            mixOutSec: best.at,
            mixInSec: mixIn,
            reason: "\(label) phrase end @\(String(format: "%.1f", best.at))s (\(best.kind))",
            confidence: confidence
        )
    }

    /// Merge energy mixOut with transcript cue (prefer transcript when confident).
    public static func blendMixOut(
        energyMixOut: Double,
        transcriptCue: Double?,
        durationSec: Double,
        minTailSec: Double = 24,
        transcriptConfidence: Double = 0.7
    ) -> (mixOut: Double, usedTranscript: Bool) {
        let window = outroWindow(durationSec: durationSec, minTailSec: minTailSec)
        func clamp(_ x: Double) -> Double {
            min(window.latest, max(window.earliest, x))
        }
        guard let transcriptCue, transcriptCue.isFinite else {
            return (clamp(energyMixOut), false)
        }
        let inWindow = transcriptCue >= window.earliest && transcriptCue <= window.latest
        let delta = abs(transcriptCue - energyMixOut)
        if inWindow, transcriptConfidence >= 0.72 {
            let w = min(0.85, 0.55 + transcriptConfidence * 0.35)
            return (clamp(energyMixOut * (1 - w) + transcriptCue * w), true)
        }
        if delta <= 12 || inWindow {
            return (clamp(energyMixOut * 0.35 + transcriptCue * 0.65), true)
        }
        return (clamp(energyMixOut), false)
    }

    private static func allWords(_ t: AutomixTranscript) -> [AutomixTranscriptWord] {
        var out: [AutomixTranscriptWord] = []
        for s in t.segments {
            if !s.words.isEmpty {
                out.append(contentsOf: s.words)
            } else {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    out.append(AutomixTranscriptWord(text: text, start: s.start, end: s.end))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
