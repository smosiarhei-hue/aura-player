import SwiftUI
import AVFoundation
import UIKit

// MARK: - 1. Data Models (Deterministic Stable IDs & Swift 6 Concurrency)

/// Single word in kinetic typography with timing and emphasis metadata.
struct LyricWord: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let isImpact: Bool

    init(
        id: String,
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        isImpact: Bool = false
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.isImpact = isImpact
    }

    var endTime: TimeInterval {
        startTime + duration
    }
}

/// Phrase unit containing timed words and visual style flags (HDR glow).
struct LyricPhrase: Identifiable, Sendable, Equatable {
    let id: String
    let timeRange: ClosedRange<TimeInterval>
    let words: [LyricWord]
    let isOutlined: Bool
    let glowIntensity: Double

    init(
        id: String,
        timeRange: ClosedRange<TimeInterval>,
        words: [LyricWord],
        isOutlined: Bool = false,
        glowIntensity: Double = 1.0
    ) {
        self.id = id
        self.timeRange = timeRange
        self.words = words
        self.isOutlined = isOutlined
        self.glowIntensity = glowIntensity
    }

    var text: String {
        words.map(\.text).joined(separator: " ")
    }

    /// Converts standard lyrics lines into natural kinetic phrases with deterministic stable IDs.
    static func from(lines: [LyricsLine]) -> [LyricPhrase] {
        var phrases: [LyricPhrase] = []
        for (index, line) in lines.enumerated() {
            let phraseId = "p_\(index)_\(Int(line.startTime * 1000))"
            let nextStart = (index + 1 < lines.count) ? lines[index + 1].startTime : (line.startTime + 4.0)
            let duration = max(1.2, line.endTime.map { $0 - line.startTime } ?? (nextStart - line.startTime))
            let end = line.startTime + duration

            let words: [LyricWord]
            if let lineWords = line.words, !lineWords.isEmpty {
                words = lineWords.enumerated().map { wordIdx, w in
                    let wDur = max(0.12, w.endTime - w.startTime)
                    let isImp = w.text.count > 5 || w.text.contains("!")
                    return LyricWord(
                        id: "\(phraseId)_w\(wordIdx)",
                        text: w.text,
                        startTime: w.startTime,
                        duration: wDur,
                        isImpact: isImp
                    )
                }
            } else {
                let tokens = line.text.split(separator: " ").map(String.init)
                let wordDur = duration / Double(max(1, tokens.count))
                words = tokens.enumerated().map { i, token in
                    let wStart = line.startTime + Double(i) * wordDur
                    let isImp = token.count >= 6 || (i == tokens.count - 1 && token.count >= 4)
                    return LyricWord(
                        id: "\(phraseId)_w\(i)",
                        text: token,
                        startTime: wStart,
                        duration: wordDur,
                        isImpact: isImp
                    )
                }
            }

            phrases.append(LyricPhrase(
                id: phraseId,
                timeRange: line.startTime...end,
                words: words,
                isOutlined: false,
                glowIntensity: 1.35
            ))
        }
        return phrases
    }
}

// MARK: - 2. Native SwiftUI Centered Flow Layout (Zero Font Shifting)

struct LyricsFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxLineWidth = max(maxLineWidth, currentX)
        }
        return CGSize(width: maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var lineHeights: [CGFloat] = [0]
        var lineWidths: [CGFloat] = [0]
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > maxWidth, !lines[lines.count - 1].isEmpty {
                lineWidths[lineWidths.count - 1] = max(0, currentLineWidth - spacing)
                lineHeights[lineHeights.count - 1] = currentLineHeight
                lines.append([])
                lineWidths.append(0)
                lineHeights.append(0)
                currentLineWidth = 0
                currentLineHeight = 0
            }
            lines[lines.count - 1].append((index, size))
            currentLineHeight = max(currentLineHeight, size.height)
            currentLineWidth += size.width + spacing
        }
        if !lines[lines.count - 1].isEmpty {
            lineWidths[lineWidths.count - 1] = max(0, currentLineWidth - spacing)
            lineHeights[lineHeights.count - 1] = currentLineHeight
        }

        var y = bounds.minY
        for (lineIndex, line) in lines.enumerated() {
            let totalLineWidth = lineWidths[lineIndex]
            let startX = bounds.minX + max(0, (bounds.width - totalLineWidth) / 2) // Centered
            var x = startX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += lineHeights[lineIndex] + lineSpacing
        }
    }
}

// MARK: - 3. 120 Hz Smooth Syllable Karaoke Highlight Word View

struct KineticWordView: View {
    let word: LyricWord
    let currentTime: TimeInterval
    let fontSize: CGFloat

    var progress: CGFloat {
        if currentTime <= word.startTime { return 0 }
        if currentTime >= word.endTime { return 1 }
        let dur = max(0.06, word.endTime - word.startTime)
        return min(1, max(0, CGFloat((currentTime - word.startTime) / dur)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Un-sung base text (Dimmed, rock-solid font weight)
            Text(word.text.uppercased())
                .font(.system(size: fontSize, weight: .heavy, design: .default))
                .foregroundStyle(Color.white.opacity(0.35))

            // Sung glowing text revealed smoothly at 120 Hz across characters
            Text(word.text.uppercased())
                .font(.system(size: fontSize, weight: .heavy, design: .default))
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.85), radius: 6, y: 2)
                .shadow(color: Color.white.opacity(progress > 0 && progress < 1 ? 0.95 : 0.40), radius: 8)
                .shadow(color: Color.cyan.opacity(progress > 0 && progress < 1 ? 0.60 : 0.0), radius: 14)
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: geo.size.width * progress)
                    }
                }
        }
    }
}

// MARK: - 4. High-Performance Kinetic Typography Component (120 Hz ProMotion, Zero Flicker)

struct KineticLyricsView: View {
    let phrases: [LyricPhrase]
    @Binding var currentTime: TimeInterval
    var isPlaying: Bool = true
    var onPhraseChange: ((LyricPhrase) -> Void)? = nil

    var body: some View {
        // Native 120 FPS timeline synchronizing directly with iPhone ProMotion display
        TimelineView(.animation(paused: !isPlaying)) { _ in
            let current = findCurrentPhrase(at: currentTime)

            ZStack {
                if let phrase = current {
                    KineticPhraseStage(
                        phrase: phrase,
                        currentTime: currentTime
                    )
                    .id(phrase.id)
                    .transition(.opacity)
                } else {
                    Text("SONIVO")
                        .font(.system(size: 26, weight: .heavy, design: .default))
                        .tracking(4.0)
                        .foregroundStyle(Color.white.opacity(0.35))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: current?.id)
            .onChange(of: current?.id) { _, _ in
                if let current {
                    onPhraseChange?(current)
                }
            }
        }
    }

    /// Fast binary search to pinpoint phrase even during rapid scrubbing
    private func findCurrentPhrase(at time: TimeInterval) -> LyricPhrase? {
        guard !phrases.isEmpty else { return nil }

        var low = 0
        var high = phrases.count - 1
        var candidate: LyricPhrase? = nil

        while low <= high {
            let mid = (low + high) / 2
            let p = phrases[mid]
            if p.timeRange.contains(time) {
                return p
            } else if p.timeRange.lowerBound > time {
                high = mid - 1
            } else {
                candidate = p
                low = mid + 1
            }
        }
        return candidate
    }
}

// MARK: - 5. Phrase Stage (Centered, 120 Hz Progressive Word Glow)

private struct KineticPhraseStage: View {
    let phrase: LyricPhrase
    let currentTime: TimeInterval

    private var baseFontSize: CGFloat { 32 }

    var body: some View {
        LyricsFlowLayout(spacing: 8, lineSpacing: 10) {
            ForEach(phrase.words) { word in
                KineticWordView(
                    word: word,
                    currentTime: currentTime,
                    fontSize: baseFontSize
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}
