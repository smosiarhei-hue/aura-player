import SwiftUI

/// Beat-reactive lyric typography rendered in the artwork area.
struct KineticLyricsArtwork: View {
    let phrase: String
    let beat: CGFloat
    let isPlaying: Bool
    let reduceMotion: Bool
    let onOpenLyrics: () -> Void

    @State private var entryScale: CGFloat = 1
    @State private var entryOpacity: Double = 1

    private var lines: [String] {
        let words = phrase
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return ["…"] }
        let targetCount = words.count <= 4 ? 1 : (words.count <= 8 ? 2 : 3)
        guard targetCount > 1 else { return [words.joined(separator: " ").uppercased()] }

        var result = Array(repeating: "", count: targetCount)
        let totalCharacters = words.reduce(0) { $0 + $1.count } + max(words.count - 1, 0)
        let targetLength = max(totalCharacters / targetCount, 1)
        var lineIndex = 0
        for word in words {
            let proposedLength = result[lineIndex].isEmpty
                ? word.count
                : result[lineIndex].count + 1 + word.count
            let remainingWords = words.count - words.prefix(while: { $0 != word }).count
            if lineIndex < targetCount - 1,
               !result[lineIndex].isEmpty,
               proposedLength > targetLength,
               remainingWords >= targetCount - lineIndex - 1 {
                lineIndex += 1
            }
            result[lineIndex] += result[lineIndex].isEmpty ? word : " " + word
        }
        return result.filter { !$0.isEmpty }.map { $0.uppercased() }
    }

    var body: some View {
        Button(action: onOpenLyrics) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !isPlaying)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let impact = reduceMotion ? 0 : min(max((beat - 0.58) / 0.42, 0), 1)
                let shakeX = sin(time * .pi * 44) * impact * 12
                let shakeY = cos(time * .pi * 38) * impact * 7
                let driftX = reduceMotion ? 0 : sin(time * 0.72) * 2.5
                let driftY = reduceMotion ? 0 : cos(time * 0.57) * 2
                let idleScale = reduceMotion ? 1 : 1.015 + sin(time * 0.85) * 0.015

                ZStack {
                    Color.black

                    if impact > 0.68 {
                        Color.white
                            .opacity(Double((impact - 0.68) * 0.22))
                            .blendMode(.screen)
                    }

                    if impact > 0.48 {
                        typography(color: .cyan.opacity(Double(impact * 0.24)))
                            .offset(x: -3.5 * impact)
                            .blendMode(.screen)
                        typography(color: .pink.opacity(Double(impact * 0.22)))
                            .offset(x: 3.5 * impact)
                            .blendMode(.screen)
                    }

                    typography(color: .white)
                        .shadow(color: .white.opacity(0.95), radius: 3)
                        .shadow(color: .white.opacity(0.48), radius: 34)
                        .shadow(color: .white.opacity(0.24), radius: 78)
                }
                .compositingGroup()
                .scaleEffect(entryScale * idleScale)
                .opacity(entryOpacity)
                .rotationEffect(.degrees(reduceMotion ? 0 : -5.5))
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : 4),
                    axis: (x: 1, y: -0.65, z: 0),
                    perspective: 0.55
                )
                .offset(x: shakeX + driftX, y: shakeY + driftY)
                .blur(radius: impact > 0.82 ? 0.55 : 0)
                .brightness(impact > 0.70 ? Double((impact - 0.70) * 0.42) : 0)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .clipped()
        .accessibilityLabel(phrase)
        .accessibilityHint("Открывает полный текст песни")
        .onAppear(perform: animateEntry)
        .onChange(of: phrase) { _, _ in animateEntry() }
    }

    private func typography(color: Color) -> some View {
        VStack(spacing: -2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                lyricLine(line, accent: index == lines.count - 1, color: color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private func lyricLine(_ line: String, accent: Bool, color: Color) -> some View {
        if accent {
            Text(line)
                .font(.custom("Arial Black", size: 38))
                .italic()
                .tracking(-1.25)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.48)
        } else {
            Text(line)
                .font(.custom("Arial Black", size: 31))
                .tracking(-1.0)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.52)
        }
    }

    private func animateEntry() {
        guard !reduceMotion else {
            entryScale = 1
            entryOpacity = 1
            return
        }
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            entryScale = 0.80
            entryOpacity = 0.60
        }
        withAnimation(.interpolatingSpring(stiffness: 520, damping: 24)) {
            entryScale = 1.06
            entryOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.10)) {
                entryScale = 1
            }
        }
    }
}
