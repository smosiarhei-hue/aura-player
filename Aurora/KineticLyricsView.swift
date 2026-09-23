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

    /// Converts standard lyrics lines into kinetic phrases with adaptive accent styling.
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

            // Alternating outline accent style on selected punchlines
            let isOutlined = (index % 5 == 3)
            let glow = isOutlined ? 0.75 : 1.35

            phrases.append(LyricPhrase(
                timeRange: line.startTime...end,
                words: words,
                isOutlined: isOutlined,
                glowIntensity: glow
            ))
        }
        return phrases
    }
}

// MARK: - 2. High-Performance Kinetic Typography Component (Calm Motion, True EDR/HDR)

struct KineticLyricsView: View {
    let phrases: [LyricPhrase]
    @Binding var currentTime: TimeInterval
    var isPlaying: Bool = true
    var onPhraseChange: ((LyricPhrase) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spectrum = SpectrumAnalyzer.shared

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
        // High-precision timeline for smooth time synchronization
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { _ in
            let current = findCurrentPhrase(at: currentTime)

            // Organic, calm breathing pulse under the beat (max 2.5% scale)
            let kick = isPlaying && !reduceMotion ? Double(spectrum.kick) : 0
            let bass = isPlaying && !reduceMotion ? Double(spectrum.bass) : 0
            let beatEnergy = min(1.0, max(kick, bass * 0.72))
            let beatScale: CGFloat = 1.0 + CGFloat(beatEnergy) * 0.024
            let beatGlow: Double = 1.0 + beatEnergy * 0.45

            ZStack {
                if let phrase = current {
                    KineticPhraseStage(
                        phrase: phrase,
                        currentTime: currentTime,
                        beatGlow: beatGlow
                    )
                    .id(phrase.id)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
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
            .scaleEffect(beatScale)
            .animation(.linear(duration: 0.045), value: beatScale)
            .animation(.easeInOut(duration: 0.35), value: current?.id)
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

// MARK: - 3. Adaptive Two-Layer Phrase Stage with Apple EDR / HDR Lighting

private struct KineticPhraseStage: View {
    let phrase: LyricPhrase
    let currentTime: TimeInterval
    let beatGlow: Double

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

    var body: some View {
        VStack(spacing: 8) {
            if phrase.isOutlined {
                // Vector Stroked Outline Mode via Canvas
                vectorOutlinedStage
            } else {
                // Solid High-Dynamic-Range Two-Layer Typography
                solidTwoLayerStage
            }
        }
        .frame(maxWidth: .infinity)
        .compositingGroup()
        .drawingGroup(opaque: false, colorMode: .extendedLinear)
        .allowedDynamicRange(.high)
    }

    // MARK: - Solid Two-Layer Kinetic Layout

    @ViewBuilder
    private var solidTwoLayerStage: some View {
        let split = partitionWords(phrase.words)

        VStack(spacing: 6) {
            // Layer 1: Context words (slightly smaller, punchy headline)
            if !split.context.isEmpty {
                HStack(alignment: .center, spacing: 9) {
                    ForEach(split.context) { word in
                        wordView(word: word, fontSize: 21, weight: .bold)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .minimumScaleFactor(0.75)
            }

            // Layer 2: Hero words (large, heavy, bold display grotesk)
            HStack(alignment: .center, spacing: 11) {
                ForEach(split.hero) { word in
                    wordView(word: word, fontSize: split.context.isEmpty ? 38 : 36, weight: .heavy)
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .minimumScaleFactor(0.70)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func wordView(word: LyricWord, fontSize: CGFloat, weight: Font.Weight) -> some View {
        let isCurrent = (word.startTime <= currentTime && currentTime <= word.endTime)
        let isPast = currentTime > word.endTime

        // Triple-pass EDR additive glow for the active singing word
        ZStack {
            // Ambient Aura Pass
            Text(word.text.uppercased())
                .font(.system(size: fontSize, weight: weight, design: .default))
                .foregroundStyle(hdrCyanAura.opacity(isCurrent ? (0.65 * beatGlow * phrase.glowIntensity) : 0.0))
                .blur(radius: isCurrent ? 20 : 0)
                .blendMode(.plusLighter)

            // Razor Bloom Pass
            Text(word.text.uppercased())
                .font(.system(size: fontSize, weight: weight, design: .default))
                .foregroundStyle(hdrBloomWhite.opacity(isCurrent ? (0.85 * beatGlow) : 0.0))
                .blur(radius: isCurrent ? 6 : 0)
                .blendMode(.plusLighter)

            // Sharp Solid Core Pass
            Text(word.text.uppercased())
                .font(.system(size: fontSize, weight: weight, design: .default))
                .foregroundStyle(
                    isCurrent
                        ? hdrCoreWhite
                        : (isPast ? Color.white.opacity(0.92) : Color.white.opacity(0.60))
                )
        }
        .brightness(isCurrent ? 0.15 : 0.0)
        .animation(.easeInOut(duration: 0.22), value: isCurrent)
    }

    /// Partitions words into context intro and hero punchline
    private func partitionWords(_ words: [LyricWord]) -> (context: [LyricWord], hero: [LyricWord]) {
        guard words.count > 2 else {
            return ([], words)
        }

        // Check if there is an explicit impact/climax word
        if let impactIdx = words.firstIndex(where: { $0.isImpact }), impactIdx > 0 {
            return (Array(words.prefix(impactIdx)), Array(words.suffix(from: impactIdx)))
        }

        // Split roughly into 2 balanced layers
        let splitPoint = max(1, words.count / 2)
        return (Array(words.prefix(splitPoint)), Array(words.suffix(from: splitPoint)))
    }

    // MARK: - Vector Outline Stage via CoreText & Canvas

    @ViewBuilder
    private var vectorOutlinedStage: some View {
        let split = partitionWords(phrase.words)

        VStack(spacing: 6) {
            if !split.context.isEmpty {
                let contextText = split.context.map(\.text).joined(separator: " ").uppercased()
                CanvasOutlineText(
                    text: contextText,
                    fontSize: 22,
                    strokeColor: hdrCyanAura,
                    coreColor: hdrCoreWhite,
                    lineWidth: 1.8
                )
                .frame(height: 34)
            }

            let heroText = split.hero.map(\.text).joined(separator: " ").uppercased()
            CanvasOutlineText(
                text: heroText,
                fontSize: split.context.isEmpty ? 38 : 36,
                strokeColor: hdrCyanAura,
                coreColor: hdrCoreWhite,
                lineWidth: 2.2
            )
            .frame(height: 52)
        }
        .padding(.horizontal, 16)
        .shadow(color: hdrCyanAura.opacity(0.60 * beatGlow), radius: 18)
    }
}

// MARK: - 4. CoreText Vector Stroked Canvas Renderer

private struct CanvasOutlineText: View {
    let text: String
    let fontSize: CGFloat
    let strokeColor: Color
    let coreColor: Color
    let lineWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
            let vectorPath = textToPath(text, font: font)
            let pathBounds = vectorPath.boundingRect
            guard !pathBounds.isEmpty else { return }

            let scale = min(1.0, (size.width - 24) / max(1.0, pathBounds.width))
            let origin = CGPoint(
                x: (size.width - pathBounds.width * scale) / 2,
                y: (size.height - pathBounds.height * scale) / 2
            )

            let transform = CGAffineTransform(translationX: origin.x, y: origin.y)
                .scaledBy(x: scale, y: scale)
            let centeredPath = vectorPath.applying(transform)

            // Outer Bloom Stroke
            context.stroke(
                centeredPath,
                with: .color(strokeColor.opacity(0.85)),
                style: StrokeStyle(lineWidth: lineWidth * 2.5, lineJoin: .round)
            )

            // Core Sharp Stroke
            context.stroke(
                centeredPath,
                with: .color(coreColor),
                style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round)
            )
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

// MARK: - 5. Standalone Interactive Simulator & Preview

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
            isOutlined: true,
            glowIntensity: 0.8
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
