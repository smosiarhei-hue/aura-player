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
    let text: String
    let timeRange: ClosedRange<TimeInterval>
    let words: [LyricWord]
    let hasWordTimings: Bool
    let isOutlined: Bool
    let glowIntensity: Double

    init(
        id: String,
        text: String,
        timeRange: ClosedRange<TimeInterval>,
        words: [LyricWord],
        hasWordTimings: Bool,
        isOutlined: Bool = false,
        glowIntensity: Double = 1.0
    ) {
        self.id = id
        self.text = text
        self.timeRange = timeRange
        self.words = words
        self.hasWordTimings = hasWordTimings
        self.isOutlined = isOutlined
        self.glowIntensity = glowIntensity
    }

    /// Converts standard lyrics lines into natural kinetic phrases with deterministic stable IDs.
    static func from(lines: [LyricsLine]) -> [LyricPhrase] {
        var phrases: [LyricPhrase] = []
        for (index, line) in lines.enumerated() {
            let phraseId = "p_\(index)_\(Int(line.startTime * 1000))"
            let nextStart = (index + 1 < lines.count) ? lines[index + 1].startTime : (line.startTime + 4.0)
            let sourceEnd = line.endTime ?? nextStart
            let end = max(line.startTime + 0.02, min(sourceEnd, nextStart))

            let hasWords = line.hasRealWordTimings
            let effective = hasWords ? (line.words ?? []) : []
            let words: [LyricWord] = effective.enumerated().map { wordIdx, w in
                let wDur = max(0.02, w.endTime - w.startTime)
                let isImp = w.text.count > 6 || w.text.contains("!")
                return LyricWord(
                    id: "\(phraseId)_w\(wordIdx)",
                    text: w.text,
                    startTime: w.startTime,
                    duration: wDur,
                    isImpact: isImp
                )
            }

            phrases.append(LyricPhrase(
                id: phraseId,
                text: line.text,
                timeRange: line.startTime...end,
                words: words,
                hasWordTimings: hasWords,
                isOutlined: false,
                glowIntensity: 1.0
            ))
        }
        return phrases
    }
}

// MARK: - 2. Multiline Word Flow Layout (Wraps words naturally with alignment)

struct LyricsFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
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
        return CGSize(width: min(maxWidth, maxLineWidth), height: currentY + lineHeight)
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
            let startX: CGFloat
            if alignment == .center {
                startX = bounds.minX + max(0, (bounds.width - totalLineWidth) / 2)
            } else {
                startX = bounds.minX
            }
            var x = startX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += lineHeights[lineIndex] + lineSpacing
        }
    }
}

// MARK: - 3. Source-timed word highlight (no entrance delay)

struct KineticWordView: View {
    let word: LyricWord
    let currentTime: TimeInterval
    let fontSize: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(word.text)
            .font(.system(size: fontSize, weight: .bold, design: .default))
            .foregroundStyle(LyricsTimingStandard.hasStarted(time: currentTime, start: word.startTime)
                ? Color.white : Color.white.opacity(0.32))
            .shadow(color: contrast != .increased && LyricsTimingStandard.hasStarted(time: currentTime, start: word.startTime)
                ? SN.accent.opacity(0.28) : .clear, radius: 5)
            .lineLimit(1)
            .minimumScaleFactor(0.70)
            .transaction { $0.animation = nil }
    }
}

// MARK: - 4. High-Performance Kinetic Typography Component (120 Hz ProMotion, Zero Flicker)

struct KineticLyricsView: View {
    let phrases: [LyricPhrase]
    @Binding var currentTime: TimeInterval
    var isPlaying: Bool = true
    var fontSize: CGFloat = 26
    var onPhraseChange: ((LyricPhrase) -> Void)? = nil
    var sampleTime: (() -> TimeInterval)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120.0,
            paused: !isPlaying || reduceMotion || scenePhase != .active)) { _ in
            let smoothTime = sampleTime?() ?? currentTime
            let (current, next) = findCurrentAndNextPhrase(at: smoothTime)

            ZStack {
                if let phrase = current {
                    KineticPhraseStage(
                        phrase: phrase,
                        nextPhrase: next,
                        currentTime: smoothTime,
                        baseFontSize: fontSize
                    )
                    .id(phrase.id)
                    .transition(.identity)
                } else if let next {
                    // Музыкальная пауза / интро: отображаем аккуратную плашку подготовки к следующей строке
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                        Text(next.text)
                            .font(.system(size: fontSize * 0.88, weight: .bold, design: .default))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .minimumScaleFactor(0.70)
                            .padding(.horizontal, 16)
                    }
                    .transition(.identity)
                } else {
                    Text("SONIVO")
                        .font(.system(size: 24, weight: .bold, design: .default))
                        .tracking(3.0)
                        .foregroundStyle(Color.white.opacity(0.35))
                        .transition(.identity)
                }
            }
            .transaction { $0.animation = nil }
            .onChange(of: current?.id) { _, _ in
                if let current {
                    onPhraseChange?(current)
                }
            }
        }
    }

    /// Keep the selected phrase until the next source start, just like Lines.
    private func findCurrentAndNextPhrase(at time: TimeInterval) -> (current: LyricPhrase?, next: LyricPhrase?) {
        guard !phrases.isEmpty else { return (nil, nil) }

        guard let index = phrases.indices.last(where: { phrases[$0].timeRange.lowerBound <= time }) else {
            return (nil, phrases.first)
        }
        let next = index + 1 < phrases.count ? phrases[index + 1] : nil
        return (phrases[index], next)
    }
}

// MARK: - 5. Phrase Stage (Dedicated SF Pro Rounded Typography, Zero Dots, Vibrant White Vocal Sweep)

private struct KineticPhraseStage: View {
    let phrase: LyricPhrase
    let nextPhrase: LyricPhrase?
    let currentTime: TimeInterval
    var baseFontSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 16) {
            // Активная строка: караоке с ядерным белым пробегом по словам
            if !phrase.words.isEmpty {
                LyricsFlowLayout(spacing: 8, lineSpacing: 9, alignment: .center) {
                    ForEach(phrase.words) { word in
                        KineticWordView(
                            word: word,
                            currentTime: currentTime,
                            fontSize: baseFontSize
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            } else {
                Text(phrase.text)
                    .font(.system(size: baseFontSize, weight: .bold, design: .default))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.40), radius: 3, y: 1.5)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.70)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }

            // Следующая строка (превью): шрифт SF Pro Bold, приглушенный цвет, без точек
            if let next = nextPhrase, !next.text.isEmpty {
                Text(next.text)
                    .font(.system(size: baseFontSize * 0.78, weight: .bold, design: .default))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.70)
                    .padding(.horizontal, 16)
                    .transition(.identity)
            }
        }
    }
}
