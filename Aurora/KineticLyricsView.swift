import SwiftUI
import AVFoundation

// MARK: - 1. Data Models (Swift 6 Concurrency)

/// Single word in kinetic typography with timing and emphasis metadata.
public struct LyricWord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let isImpact: Bool

    public init(
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

    public var endTime: TimeInterval {
        startTime + duration
    }
}

/// Phrase unit containing timed words and visual style flags (outline, HDR glow).
public struct LyricPhrase: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timeRange: ClosedRange<TimeInterval>
    public let words: [LyricWord]
    public let isOutlined: Bool
    public let glowIntensity: Double
    public let rotationDegrees: Double

    public init(
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

    public var text: String {
        words.map(\.text).joined(separator: " ")
    }

    /// Converts standard lyrics lines into kinetic phrases with alternating accent styles.
    public static func from(lines: [LyricsLine]) -> [LyricPhrase] {
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

public struct KineticLyricsView: View {
    public let phrases: [LyricPhrase]
    @Binding public var currentTime: TimeInterval
    public var isPlaying: Bool = true
    public var onPhraseChange: ((LyricPhrase) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activePhraseIndex: Int?
    @State private var lastSeekTime: TimeInterval = 0

    public init(
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

    public var body: some View {
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
        }
    }

    /// Fast search to pinpoint phrase even during rapid scrubbing
    private func findCurrentPhrase(at time: TimeInterval) -> LyricPhrase? {
        guard !phrases.isEmpty else { return nil }

        // Check if current cached phrase is still valid
        if let idx = activePhraseIndex, phrases.indices.contains(idx) {
            let p = phrases[idx]
            if p.timeRange.contains(time) { return p }
            if idx + 1 < phrases.count, phrases[idx + 1].timeRange.contains(time) {
                Task { @MainActor in
                    activePhraseIndex = idx + 1
                    onPhraseChange?(phrases[idx + 1])
                }
                return phrases[idx + 1]
            }
        }

        // Binary search for seek / jump
        var low = 0
        var high = phrases.count - 1
        var candidate: LyricPhrase? = nil
        var candidateIdx: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            let p = phrases[mid]
            if p.timeRange.contains(time) {
                candidate = p
                candidateIdx = mid
                break
            } else if p.timeRange.lowerBound > time {
                high = mid - 1
            } else {
                candidate = p
                candidateIdx = mid
                low = mid + 1
            }
        }

        if let candidateIdx, candidateIdx != activePhraseIndex {
            Task { @MainActor in
                activePhraseIndex = candidateIdx
                if let c = candidate { onPhraseChange?(c) }
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
                // Vector Stroked Outline Mode
                Canvas { context, size in
                    let text = Text(phrase.text.uppercased())
                        .font(.system(size: 38, weight: .heavy, design: .default))
                    let resolved = context.resolve(text)
                    let origin = CGPoint(
                        x: (size.width - resolved.measure(in: size).width) / 2,
                        y: (size.height - resolved.measure(in: size).height) / 2
                    )

                    // Draw outer bloom stroke
                    context.stroke(
                        resolved,
                        at: origin,
                        with: .color(.cyan.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 6, lineJoin: .round)
                    )

                    // Draw razor-sharp core stroke
                    context.stroke(
                        resolved,
                        at: origin,
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

public struct KineticLyricsDemoSimulatorView: View {
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

    public init() {}

    public var body: some View {
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
