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
            let duration = max(1.2, line.endTime.map { $0 - line.startTime } ?? (nextStart - line.startTime))
            let end = line.startTime + duration

            let hasWords = line.hasRealWordTimings
            let effective = hasWords ? (line.words ?? []) : []
            let words: [LyricWord] = effective.enumerated().map { wordIdx, w in
                let wDur = max(0.08, w.endTime - w.startTime)
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

// MARK: - 3. 120 Hz Smooth Syllable Karaoke Highlight Word View (Vibrant White Sweep, No Cursor Stick)

struct KineticWordView: View {
    let word: LyricWord
    let currentTime: TimeInterval
    let fontSize: CGFloat

    var progress: CGFloat {
        if currentTime <= word.startTime { return 0 }
        if currentTime >= word.endTime { return 1 }
        let dur = max(0.04, word.endTime - word.startTime)
        return min(1.0, max(0.0, CGFloat((currentTime - word.startTime) / dur)))
    }

    var isActivelySinging: Bool {
        progress > 0.001 && progress < 0.999
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // 1. Не спетый текст: полупрозрачный белый, стандартный Apple SF Pro Bold
            Text(word.text)
                .font(.system(size: fontSize, weight: .bold, design: .default))
                .foregroundStyle(Color.white.opacity(0.32))

            // 2. Спетый текст: чистый белый с мягкой тенью
            if progress > 0 {
                Text(word.text)
                    .font(.system(size: fontSize, weight: .bold, design: .default))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.40), radius: 2, y: 1.5)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white, location: max(0.0, progress - 0.015)),
                                .init(color: .white, location: progress),
                                .init(color: .clear, location: min(1.0, progress + 0.005)),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            // 3. Ядерный белый луч по тексту во время пения (без палочек)
            if isActivelySinging {
                Text(word.text)
                    .font(.system(size: fontSize, weight: .bold, design: .default))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.white, radius: 4)
                    .shadow(color: Color.white.opacity(0.90), radius: 8)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0.0, progress - 0.22)),
                                .init(color: .white, location: max(0.0, progress - 0.03)),
                                .init(color: .white, location: progress),
                                .init(color: .white, location: min(1.0, progress + 0.03)),
                                .init(color: .clear, location: min(1.0, progress + 0.22))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.70)
        .scaleEffect(isActivelySinging ? 1.025 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.20, dampingFraction: 0.85), value: isActivelySinging)
    }
}

// MARK: - 4. High-Performance Kinetic Typography Component (120 Hz ProMotion, Zero Flicker)

struct KineticLyricsView: View {
    let phrases: [LyricPhrase]
    @Binding var currentTime: TimeInterval
    var isPlaying: Bool = true
    var fontSize: CGFloat = 26
    var onPhraseChange: ((LyricPhrase) -> Void)? = nil

    // Hardware ProMotion clock anchor for continuous 120 Hz sub-pixel interpolation
    @State private var anchorTimestamp: Double = CACurrentMediaTime()

    var body: some View {
        // Native 120 FPS timeline synchronizing directly with iPhone ProMotion display
        TimelineView(.animation(paused: !isPlaying)) { _ in
            let now = CACurrentMediaTime()
            let dt = isPlaying ? max(0.0, min(0.025, now - anchorTimestamp)) : 0.0
            let smoothTime = currentTime + dt
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
                    .transition(.opacity)
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
                    .transition(.opacity)
                } else {
                    Text("SONIVO")
                        .font(.system(size: 24, weight: .bold, design: .default))
                        .tracking(3.0)
                        .foregroundStyle(Color.white.opacity(0.35))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: current?.id)
            .onChange(of: currentTime) { _, _ in
                anchorTimestamp = CACurrentMediaTime()
            }
            .onChange(of: current?.id) { _, _ in
                if let current {
                    onPhraseChange?(current)
                }
            }
        }
    }

    /// Fast search to pinpoint active and next phrase with strict intro & instrumental break detection
    private func findCurrentAndNextPhrase(at time: TimeInterval) -> (current: LyricPhrase?, next: LyricPhrase?) {
        guard !phrases.isEmpty else { return (nil, nil) }

        // 1. Интро: вокал еще не начался
        if let first = phrases.first, time < first.timeRange.lowerBound {
            return (nil, first)
        }

        // 2. Поиск активной фразы во время пения
        for (i, p) in phrases.enumerated() {
            if p.timeRange.contains(time) {
                let nxt = (i + 1 < phrases.count) ? phrases[i + 1] : nil
                return (p, nxt)
            }
        }

        // 3. Инструментальная пауза между фразами
        for i in 0..<(phrases.count - 1) {
            let cur = phrases[i]
            let nxt = phrases[i + 1]
            if time > cur.timeRange.upperBound && time < nxt.timeRange.lowerBound {
                let gap = nxt.timeRange.lowerBound - cur.timeRange.upperBound
                if gap <= 1.5 {
                    // Короткая пауза на вдох: удерживаем текущую фразу
                    return (cur, nxt)
                } else {
                    // Длинный проигрыш / дроп / соло: переключаем в режим ожидания следующей строки
                    return (nil, nxt)
                }
            }
        }

        // 4. После последней фразы
        if let last = phrases.last, time >= last.timeRange.lowerBound {
            return (last, nil)
        }

        return (nil, nil)
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
                    .transition(.opacity)
            }
        }
    }
}
