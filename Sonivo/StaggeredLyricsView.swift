import SwiftUI
import AVFoundation

/// Native implementation inspired by Staggered Text's documented word reveal.
/// No React dependency or proprietary React Bits Pro source is included.
nonisolated enum StaggeredLyricsMath {
    static func timing(wordCount: Int, availableDuration: Double) -> (duration: Double, delay: Double, total: Double) {
        let count = max(1, wordCount)
        let budget = min(1.8, max(0.12, availableDuration * 0.70))
        let duration = min(0.60, max(0.12, budget * 0.55))
        let delay = count > 1 ? min(0.08, max(0, budget - duration) / Double(count - 1)) : 0
        return (duration, delay, duration + delay * Double(count - 1))
    }

    static func reveal(elapsed: Double, index: Int, duration: Double, delay: Double) -> Double {
        let value = min(1, max(0, (elapsed - Double(index) * delay) / max(0.01, duration)))
        return 1 - pow(1 - value, 3)
    }

    static func segments(_ text: String) -> [String] {
        // Preserve whitespace, punctuation, newlines and Unicode graphemes.
        var result: [String] = []
        var segment = ""
        var lastWasWhitespace = false
        for character in text {
            if !character.isWhitespace && lastWasWhitespace && !segment.isEmpty {
                result.append(segment)
                segment = ""
            }
            segment.append(character)
            lastWasWhitespace = character.isWhitespace
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }
}

nonisolated struct StaggeredWordAttribute: TextAttribute {
    let index: Int
    let startTime: Double?
    let endTime: Double?
}

/// TextRenderer keeps native shaping, wrapping and punctuation intact; words are
/// drawn independently without turning the sentence into a row of separate views.
nonisolated struct StaggeredLyricsRenderer: TextRenderer {
    var elapsed: Double
    let duration: Double
    let delay: Double
    let currentTime: Double?
    let isActive: Bool
    let reduceMotion: Bool
    let inactiveOpacity: Double

    var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let attribute = run[StaggeredWordAttribute.self]
                let progress = reduceMotion || !isActive ? 1 : StaggeredLyricsMath.reveal(
                    elapsed: elapsed, index: attribute?.index ?? 0, duration: duration, delay: delay)
                var copy = context
                copy.opacity *= isActive ? (0.22 + 0.78 * progress) : inactiveOpacity
                if isActive && !reduceMotion {
                    copy.translateBy(x: 0, y: -14 * (1 - progress))
                    copy.addFilter(.blur(radius: 5 * (1 - progress)))
                }
                if isActive, let time = currentTime,
                   let start = attribute?.startTime, let end = attribute?.endTime, end > start {
                    // Real source word timings retain the karaoke sweep. Stagger delay
                    // is a visual entrance, never substituted for an audio timestamp.
                    var unsung = copy
                    unsung.opacity *= 0.34
                    unsung.draw(run)
                    let sung = min(1, max(0, (time - start) / (end - start)))
                    if sung > 0 {
                        let rect = run.typographicBounds.rect
                        copy.clip(to: Path(CGRect(x: rect.minX, y: rect.minY - 6,
                                                 width: rect.width * sung, height: rect.height + 12)))
                        copy.draw(run)
                    }
                } else {
                    copy.draw(run)
                }
            }
        }
    }
}

struct StaggeredLyricText: View {
    let text: String
    var words: [LyricsWord]? = nil
    var currentTime: Double? = nil
    var revealElapsed: Double = 0
    var availableDuration: Double = 3
    var isActive: Bool = true
    var fontSize: CGFloat = 32
    var inactiveOpacity: Double = 0.35
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var segments: [String] { StaggeredLyricsMath.segments(text) }

    private var renderedText: Text {
        let parts = segments
        let cleanParts = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Do not assign source timestamps to unrelated words if tokenization differs.
        let timingsMatch = words?.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } == cleanParts
        return parts.enumerated().reduce(Text("")) { result, pair in
            let word = timingsMatch ? words?[pair.offset] : nil
            let token = Text(pair.element).customAttribute(StaggeredWordAttribute(
                index: pair.offset, startTime: word?.startTime, endTime: word?.endTime))
            return result + token
        }
    }

    var body: some View {
        let timing = StaggeredLyricsMath.timing(wordCount: segments.count, availableDuration: availableDuration)
        renderedText
            .font(.system(size: fontSize, weight: .bold, design: .default))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .textRenderer(StaggeredLyricsRenderer(elapsed: revealElapsed, duration: timing.duration,
                delay: timing.delay, currentTime: currentTime, isActive: isActive,
                reduceMotion: reduceMotion, inactiveOpacity: inactiveOpacity))
            .accessibilityLabel(text)
    }
}

private struct StaggeredStaticLyricRow: View {
    let text: String
    let fontSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        let timing = StaggeredLyricsMath.timing(wordCount: StaggeredLyricsMath.segments(text).count, availableDuration: 3)
        StaggeredLyricText(text: text, revealElapsed: revealed || reduceMotion ? timing.total : 0,
                           fontSize: fontSize)
            .onAppear {
                if reduceMotion { revealed = true }
                else { withAnimation(.linear(duration: timing.total)) { revealed = true } }
            }
    }
}

struct StaggeredLyricsView: View {
    let lyrics: Lyrics
    let player: ActivePlayerPresentation
    var showsSource: Bool = true
    var fontSize: CGFloat? = nil
    var onEditLyrics: (() -> Void)? = nil
    @State private var settings = SettingsStore.shared
    @State private var isUserInteracting = false
    @State private var interactionResetTask: Task<Void, Never>?
    @State private var activeIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var playbackTime: Double {
        max(0, player.progress - AVAudioSession.sharedInstance().outputLatency + settings.lyricsOffset)
    }
    private var resolvedFontSize: CGFloat { fontSize ?? max(30, settings.lyricsFontSize * 0.82) }

    private func activeLine(at time: Double) -> Int? {
        guard lyrics.isSynchronized, let first = lyrics.lines.first, time >= first.startTime else { return nil }
        return lyrics.lines.indices.last { lyrics.lines[$0].startTime <= time }
    }

    private func lineDuration(at index: Int) -> Double {
        let line = lyrics.lines[index]
        let next = index + 1 < lyrics.lines.count ? lyrics.lines[index + 1].startTime : line.endTime ?? line.startTime + 4
        return max(0.12, next - line.startTime)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 28) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        if lyrics.isSynchronized {
                            Button {
                                Haptics.tap(.medium)
                                interactionResetTask?.cancel()
                                isUserInteracting = false
                                // Display applies +offset and subtracts route latency;
                                // inverse compensation lands on the selected line.
                                player.seek(to: max(0, line.startTime - settings.lyricsOffset + AVAudioSession.sharedInstance().outputLatency))
                                if !player.isPlaying { player.resume() }
                            } label: {
                                StaggeredLyricText(text: line.text, words: line.hasRealWordTimings ? line.words : nil,
                                    currentTime: playbackTime, revealElapsed: max(0, playbackTime - line.startTime),
                                    availableDuration: lineDuration(at: index), isActive: index == activeIndex,
                                    fontSize: resolvedFontSize)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Перемотать к этой строке")
                            .id(index)
                        } else {
                            // Plain lyrics animate on appearance, not against invented song timings.
                            StaggeredStaticLyricRow(text: line.text, fontSize: resolvedFontSize)
                                .padding(.vertical, 8)
                                .id(index)
                        }
                    }
                    if showsSource && !lyrics.sourceName.isEmpty {
                        Text("Источник: \(lyrics.sourceName)")
                            .font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.top, 16)
                    }
                    if showsSource, let onEditLyrics {
                        Button("Изменить текст", action: onEditLyrics)
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 80)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in
                isUserInteracting = true
                interactionResetTask?.cancel()
                interactionResetTask = Task {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    isUserInteracting = false
                    centerCurrentLine(proxy: proxy)
                }
            })
            .overlay(alignment: .bottomTrailing) {
                if isUserInteracting, activeIndex != nil {
                    Button("К текущей") {
                        interactionResetTask?.cancel()
                        isUserInteracting = false
                        centerCurrentLine(proxy: proxy)
                    }
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(10).background(.ultraThinMaterial, in: Capsule()).padding(16)
                }
            }
            .onChange(of: player.progress) { _, _ in updateActiveLine(proxy: proxy) }
            .onChange(of: settings.lyricsOffset) { _, _ in updateActiveLine(proxy: proxy) }
            .onChange(of: lyrics) { _, _ in
                interactionResetTask?.cancel()
                isUserInteracting = false
                activeIndex = nil
                updateActiveLine(proxy: proxy)
            }
            .onAppear { updateActiveLine(proxy: proxy) }
            .onDisappear { interactionResetTask?.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { interactionResetTask?.cancel() }
            }
        }
    }

    private func updateActiveLine(proxy: ScrollViewProxy) {
        let next = activeLine(at: playbackTime)
        guard next != activeIndex else { return }
        activeIndex = next
        if !isUserInteracting { centerCurrentLine(proxy: proxy) }
    }

    private func centerCurrentLine(proxy: ScrollViewProxy) {
        guard let activeIndex else { return }
        if reduceMotion { proxy.scrollTo(activeIndex, anchor: .center) }
        else { withAnimation(.easeInOut(duration: 0.40)) { proxy.scrollTo(activeIndex, anchor: .center) } }
    }
}

struct LyricsDesignPreview: View {
    let design: LyricsDesign
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date().timeIntervalSinceReferenceDate

    var body: some View {
        VStack(spacing: 8) {
            if design == .staggered {
                TimelineView(.animation(minimumInterval: 1 / 30.0, paused: reduceMotion || scenePhase != .active)) { timeline in
                    let elapsed = reduceMotion ? 3 : max(0, timeline.date.timeIntervalSinceReferenceDate - start).truncatingRemainder(dividingBy: 3.2)
                    StaggeredLyricText(text: "Музыка оживает в каждой строке", revealElapsed: elapsed, fontSize: 24)
                }
            } else {
                Text("Музыка оживает в каждой строке")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            Text(design == .staggered ? "Слова появляются по очереди, мягко и с размытием" : "Привычный текст и существующая караоке-подсветка")
                .font(.caption).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(Color.black.opacity(0.90), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: design) { _, _ in start = Date().timeIntervalSinceReferenceDate }
    }
}
