import SwiftUI
import AVFoundation
import CoreText
import UIKit

// MARK: - 1. Data Models (Swift 6 Concurrency)

/// Single word in kinetic typography with timing and emphasis metadata.
struct LyricWord: Identifiable, Sendable, Equatable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let isImpact: Bool

    init(
        id: UUID = UUID(),
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

/// Phrase unit containing timed words and visual style flags (outline, HDR glow).
struct LyricPhrase: Identifiable, Sendable, Equatable {
    let id: UUID
    let timeRange: ClosedRange<TimeInterval>
    let words: [LyricWord]
    let isOutlined: Bool
    let glowIntensity: Double
    let rotationDegrees: Double

    init(
        id: UUID = UUID(),
        timeRange: ClosedRange<TimeInterval>,
        words: [LyricWord],
        isOutlined: Bool = false,
        glowIntensity: Double = 1.0,
        rotationDegrees: Double = 0.0
    ) {
        self.id = id
        self.timeRange = timeRange
        self.words = words
        self.isOutlined = isOutlined
        self.glowIntensity = glowIntensity
        self.rotationDegrees = rotationDegrees
    }

    var text: String {
        words.map(\.text).joined(separator: " ")
    }

    /// Converts standard lyrics lines into kinetic phrases with alternating accent styles.
    static func from(lines: [LyricsLine]) -> [LyricPhrase] {
        var phrases: [LyricPhrase] = []
        for (index, line) in lines.enumerated() {
            let nextStart = (index + 1 < lines.count) ? lines[index + 1].startTime : (line.startTime + 4.0)
            let duration = max(1.2, line.endTime.map { $0 - line.startTime } ?? (nextStart - line.startTime))
            let end = line.startTime + duration

            let words: [LyricWord]
            if let lineWords = line.words, !lineWords.isEmpty {
                words = lineWords.map { w in
                    let wDur = max(0.15, w.endTime - w.startTime)
                    let isImp = w.text.count > 5 || w.text.contains("!")
                    return LyricWord(text: w.text, startTime: w.startTime, duration: wDur, isImpact: isImp)
                }
            } else {
                let tokens = line.text.split(separator: " ").map(String.init)
                let wordDur = duration / Double(max(1, tokens.count))
                words = tokens.enumerated().map { i, token in
                    let wStart = line.startTime + Double(i) * wordDur
                    let isImp = token.count >= 6 || (i == 0 && index % 3 == 0)
                    return LyricWord(text: token, startTime: wStart, duration: wordDur, isImpact: isImp)
                }
            }

            // Alternate outline accents and subtle rotation angle
            let isOutlined = (index % 4 == 2)
            let rotation = (index % 2 == 0 ? 1.0 : -1.0) * (Double(index % 3) * 2.2 + 1.0)
            let glow = isOutlined ? 0.6 : 1.25

            phrases.append(LyricPhrase(
                timeRange: line.startTime...end,
                words: words,
                isOutlined: isOutlined,
                glowIntensity: glow,
                rotationDegrees: rotation
            ))
        }
        return phrases
    }
}

// MARK: - 2. High-Performance Kinetic Typography Component (120 FPS ProMotion)

struct KineticLyricsView: View {
    let phrases: [LyricPhrase]
    @Binding var currentTime: TimeInterval
    var isPlaying: Bool = true
    var onPhraseChange: ((LyricPhrase) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        phrases: [LyricPhrase],
        currentTime: Binding<TimeInterval>,
        isPlaying: Bool = true,
        onPhraseChange: ((LyricPhrase) -> Void)? = nil
    ) {
        self.phrases = phrases
        self._currentTime = currentTime
        self.isPlaying = isPlaying
        self.onPhraseChange = onPhraseChange
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120.0, paused: !isPlaying)) { _ in
            let current = findCurrentPhrase(at: currentTime)

            ZStack {
                if let phrase = current {
                    KineticPhraseStage(
                        phrase: phrase,
                        currentTime: currentTime,
                        reduceMotion: reduceMotion
                    )
                    .id(phrase.id)
                    .transition(
                        .asymmetric(
                            insertion: .modifier(
                                active: PhraseTransitionModifier(progress: 0, rotation: phrase.rotationDegrees),
                                identity: PhraseTransitionModifier(progress: 1, rotation: phrase.rotationDegrees)
                            ),
                            removal: .opacity.combined(with: .scale(scale: 0.94))
                        )
                    )
                } else {
                    Text("SONIVO")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .tracking(4.0)
                        .foregroundStyle(.white.opacity(0.35))
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: current?.id)
            .allowedDynamicRange(.high)
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

// MARK: - 3. Phrase Stage with Spring Impact, Outline & EDR Neon Glow

private struct KineticPhraseStage: View {
    let phrase: LyricPhrase
    let currentTime: TimeInterval
    let reduceMotion: Bool

    @State private var phase: ImpactPhase = .initial

    private enum ImpactPhase: CaseIterable {
        case initial
        case impact
        case settle

        var scale: CGFloat {
            switch self {
            case .initial: return 0.85
            case .impact: return 1.15
            case .settle: return 1.0
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if phrase.isOutlined {
                // Vector Stroked Outline Mode via Canvas
                let font = UIFont.systemFont(ofSize: 38, weight: .heavy)
                let vectorPath = textToPath(phrase.text.uppercased(), font: font)

                Canvas { context, size in
                    let pathBounds = vectorPath.boundingRect
                    guard !pathBounds.isEmpty else { return }

                    let scale = min(1.0, (size.width - 32) / max(1.0, pathBounds.width))
                    let origin = CGPoint(
                        x: (size.width - pathBounds.width * scale) / 2,
                        y: (size.height - pathBounds.height * scale) / 2
                    )

                    let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
                        .scaledBy(x: scale, y: scale)
                    let centeredPath = vectorPath.applying(transform)

                    // Draw outer bloom stroke
                    context.stroke(
                        centeredPath,
                        with: .color(.cyan.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 6, lineJoin: .round)
                    )

                    // Draw razor-sharp core stroke
                    context.stroke(
                        centeredPath,
                        with: .color(.white),
                        style: StrokeStyle(lineWidth: 2.2, lineJoin: .round)
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .shadow(color: .white.opacity(0.9), radius: 10)
                .shadow(color: .cyan.opacity(0.6), radius: 24)
            } else {
                // Pure Solid White with Compound HDR Neon Glow
                wordFlow(phrase: phrase)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .shadow(color: .white.opacity(0.95), radius: 6, x: 0, y: 0)
                    .shadow(color: .cyan.opacity(0.70 * phrase.glowIntensity), radius: 18, x: 0, y: 0)
                    .shadow(color: .purple.opacity(0.45 * phrase.glowIntensity), radius: 38, x: 0, y: 0)
            }
        }
        .rotationEffect(.degrees(reduceMotion ? 0 : phrase.rotationDegrees))
        .phaseAnimator(ImpactPhase.allCases, trigger: phrase.id) { content, currentPhase in
            content
                .scaleEffect(reduceMotion ? 1.0 : currentPhase.scale)
        } animation: { currentPhase in
            switch currentPhase {
            case .initial: return .easeOut(duration: 0.04)
            case .impact: return .spring(response: 0.18, dampingFraction: 0.55)
            case .settle: return .spring(response: 0.28, dampingFraction: 0.72)
            }
        }
        .compositingGroup()
        .allowedDynamicRange(.high)
    }

    @ViewBuilder
    private func wordFlow(phrase: LyricPhrase) -> some View {
        let activeWord = phrase.words.first { $0.startTime <= currentTime && currentTime <= $0.endTime }

        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                ForEach(phrase.words) { word in
                    let isCurrent = (word.id == activeWord?.id)
                    let wordPast = currentTime > word.endTime

                    Text(word.text.uppercased())
                        .font(.system(size: 38, weight: .heavy, design: .default))
                        .foregroundStyle(isCurrent ? .white : (wordPast ? .white.opacity(0.88) : .white.opacity(0.38)))
                        .scaleEffect(isCurrent && word.isImpact ? 1.12 : (isCurrent ? 1.05 : 1.0))
                        .brightness(isCurrent ? 0.25 : 0.0)
                        .animation(.spring(response: 0.20, dampingFraction: 0.65), value: isCurrent)
                }
            }

            // Compact fallback for longer lyric phrases
            Text(phrase.text.uppercased())
                .font(.system(size: 32, weight: .heavy, design: .default))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }

    @MainActor
    private func textToPath(_ string: String, font: UIFont) -> Path {
        guard !string.isEmpty else { return Path() }
        let ctFont = font as CTFont
        let attrString = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return Path() }

        let letters = CGMutablePath()
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)

            for i in 0..<count {
                if let glyphPath = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) {
                    var translation = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                    letters.addPath(glyphPath, transform: translation)
                }
            }
        }

        let bounds = letters.boundingBoxOfPath
        guard !bounds.isEmpty, !bounds.isNull else { return Path() }

        var transform = CGAffineTransform(scaleX: 1.0, y: -1.0)
            .translatedBy(x: -bounds.origin.x, y: -bounds.origin.y - bounds.height)

        guard let flipped = letters.copy(using: &transform) else {
            return Path(letters)
        }
        return Path(flipped)
    }
}

// MARK: - 4. Dynamic Transition Modifier (±Angle, Vertical Shift, Opacity)

private struct PhraseTransitionModifier: ViewModifier {
    let progress: Double
    let rotation: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(y: (1.0 - progress) * -16.0)
            .rotationEffect(.degrees((1.0 - progress) * rotation))
    }
}

// MARK: - 5. Standalone Interactive Simulator & Preview

struct KineticLyricsDemoSimulatorView: View {
    @State private var time: TimeInterval = 0
    @State private var isPlaying: Bool = true
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private let demoPhrases: [LyricPhrase] = [
        LyricPhrase(
            timeRange: 0.0...3.5,
            words: [
                LyricWord(text: "FEEL", startTime: 0.0, duration: 0.7, isImpact: true),
                LyricWord(text: "THE", startTime: 0.7, duration: 0.4),
                LyricWord(text: "BASSLINE", startTime: 1.1, duration: 1.2, isImpact: true),
                LyricWord(text: "DROP", startTime: 2.3, duration: 1.0, isImpact: true)
            ],
            isOutlined: false,
            glowIntensity: 1.4,
            rotationDegrees: -3.5
        ),
        LyricPhrase(
            timeRange: 3.5...7.0,
            words: [
                LyricWord(text: "GLOWING", startTime: 3.5, duration: 0.9, isImpact: true),
                LyricWord(text: "IN", startTime: 4.4, duration: 0.4),
                LyricWord(text: "THE", startTime: 4.8, duration: 0.4),
                LyricWord(text: "DARK", startTime: 5.2, duration: 1.5, isImpact: true)
            ],
            isOutlined: true,
            glowIntensity: 0.8,
            rotationDegrees: 4.0
        ),
        LyricPhrase(
            timeRange: 7.0...11.0,
            words: [
                LyricWord(text: "PURE", startTime: 7.0, duration: 0.8, isImpact: true),
                LyricWord(text: "NEON", startTime: 7.8, duration: 0.9, isImpact: true),
                LyricWord(text: "ENERGY", startTime: 8.7, duration: 2.0, isImpact: true)
            ],
            isOutlined: false,
            glowIntensity: 1.6,
            rotationDegrees: -2.0
        )
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            KineticLyricsView(
                phrases: demoPhrases,
                currentTime: $time,
                isPlaying: isPlaying
            )
            .frame(height: 180)

            Spacer()

            // Time & Transport Controls
            VStack(spacing: 12) {
                HStack {
                    Text(formatTime(time))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.white.opacity(0.6))
                    Slider(value: $time, in: 0...11.0)
                        .tint(.cyan)
                    Text("0:11")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 24)

                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white)
                }
            }
            .padding(.bottom, 34)
        }
        .background(Color.black.ignoresSafeArea())
        .onReceive(timer) { _ in
            if isPlaying {
                time += 1.0 / 60.0
                if time > 11.0 { time = 0 }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func formatTime(_ val: TimeInterval) -> String {
        let mins = Int(val) / 60
        let secs = Int(val) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
