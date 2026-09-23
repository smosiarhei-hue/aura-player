import SwiftUI
import AVFoundation
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

/// Phrase unit containing timed words and visual style flags (HDR glow).
struct LyricPhrase: Identifiable, Sendable, Equatable {
    let id: UUID
    let timeRange: ClosedRange<TimeInterval>
    let words: [LyricWord]
    let isOutlined: Bool
    let glowIntensity: Double

    init(
        id: UUID = UUID(),
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

    /// Converts standard lyrics lines into natural kinetic phrases.
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
                    let isImp = token.count >= 6 || (i == tokens.count - 1 && token.count >= 4)
                    return LyricWord(text: token, startTime: wStart, duration: wordDur, isImpact: isImp)
                }
            }

            phrases.append(LyricPhrase(
                timeRange: line.startTime...end,
                words: words,
                isOutlined: false,
                glowIntensity: 1.35
            ))
        }
        return phrases
    }
}

// MARK: - 2. High-Performance Kinetic Typography Component (Stable, Readable, True HDR)

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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { _ in
            let current = findCurrentPhrase(at: currentTime)

            ZStack {
                if let phrase = current {
                    KineticPhraseStage(
                        phrase: phrase,
                        currentTime: currentTime
                    )
                    .id(phrase.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity
                        )
                    )
                } else {
                    Text("SONIVO")
                        .font(.system(size: 26, weight: .heavy, design: .default))
                        .tracking(4.0)
                        .foregroundStyle(Color.white.opacity(0.35))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.30), value: current?.id)
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

// MARK: - 3. Natural Flowing Phrase Stage with True Apple EDR / HDR Lighting

private struct KineticPhraseStage: View {
    let phrase: LyricPhrase
    let currentTime: TimeInterval

    // Apple EDR Colors: exposureAdjust + headroom exceeding SDR 1.0 onto OLED panel
    private var hdrCoreWhite: Color {
        Color.white.exposureAdjust(2.2).headroom(4.5)
    }

    private var hdrBloomWhite: Color {
        Color.white.exposureAdjust(1.85).headroom(3.5)
    }

    private var hdrCyanAura: Color {
        Color.cyan.exposureAdjust(1.65).headroom(2.8)
    }

    private var baseFontSize: CGFloat {
        if phrase.words.count <= 2 {
            return 36
        } else if phrase.words.count <= 5 {
            return 32
        } else {
            return 28
        }
    }

    var body: some View {
        ZStack {
            // Ambient EDR Glow Layer
            flowText(mode: .aura)
                .blur(radius: 22)
                .blendMode(.plusLighter)

            // Sharp EDR Bloom Layer
            flowText(mode: .bloom)
                .blur(radius: 6)
                .blendMode(.plusLighter)

            // Crisp Solid Text Layer
            flowText(mode: .core)
        }
        .frame(maxWidth: .infinity)
        .compositingGroup()
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .allowedDynamicRange(.high)
    }

    private enum RenderMode {
        case aura
        case bloom
        case core
    }

    private func flowText(mode: RenderMode) -> some View {
        var text = Text("")
        for (index, word) in phrase.words.enumerated() {
            let isCurrent = (word.startTime <= currentTime && currentTime <= word.endTime)
            let isPast = currentTime > word.endTime
            let separator = (index < phrase.words.count - 1) ? " " : ""

            let wordColor: Color
            switch mode {
            case .aura:
                wordColor = isCurrent ? hdrCyanAura.opacity(0.55 * phrase.glowIntensity) : .clear
            case .bloom:
                wordColor = isCurrent ? hdrBloomWhite.opacity(0.85) : .clear
            case .core:
                wordColor = isCurrent
                    ? hdrCoreWhite
                    : (isPast ? Color.white.opacity(0.95) : Color.white.opacity(0.50))
            }

            let wordFont: Font = .system(
                size: baseFontSize,
                weight: isCurrent ? .black : .heavy,
                design: .default
            )

            let piece = Text(word.text.uppercased() + separator)
                .font(wordFont)
                .foregroundStyle(wordColor)

            text = text + piece
        }

        return text
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .lineLimit(nil)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 20)
    }
}

// MARK: - 4. Standalone Interactive Simulator & Preview

struct KineticLyricsDemoSimulatorView: View {
    @State private var time: TimeInterval = 0
    @State private var isPlaying: Bool = true
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private let demoPhrases: [LyricPhrase] = [
        LyricPhrase(
            timeRange: 0.0...3.5,
            words: [
                LyricWord(text: "FEEL", startTime: 0.0, duration: 0.7, isImpact: false),
                LyricWord(text: "THE", startTime: 0.7, duration: 0.4),
                LyricWord(text: "BASSLINE", startTime: 1.1, duration: 1.2, isImpact: true),
                LyricWord(text: "DROP", startTime: 2.3, duration: 1.0, isImpact: true)
            ],
            isOutlined: false,
            glowIntensity: 1.4
        ),
        LyricPhrase(
            timeRange: 3.5...7.0,
            words: [
                LyricWord(text: "GLOWING", startTime: 3.5, duration: 0.9, isImpact: false),
                LyricWord(text: "IN", startTime: 4.4, duration: 0.4),
                LyricWord(text: "THE", startTime: 4.8, duration: 0.4),
                LyricWord(text: "DARK", startTime: 5.2, duration: 1.5, isImpact: true)
            ],
            isOutlined: false,
            glowIntensity: 1.2
        ),
        LyricPhrase(
            timeRange: 7.0...11.0,
            words: [
                LyricWord(text: "PURE", startTime: 7.0, duration: 0.8, isImpact: false),
                LyricWord(text: "NEON", startTime: 7.8, duration: 0.9, isImpact: true),
                LyricWord(text: "ENERGY", startTime: 8.7, duration: 2.0, isImpact: true)
            ],
            isOutlined: false,
            glowIntensity: 1.6
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
