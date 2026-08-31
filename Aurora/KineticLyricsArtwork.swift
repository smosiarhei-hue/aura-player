import SwiftUI

/// Lightweight beat-reactive typography rendered directly over artwork or video.
struct KineticLyricsArtwork: View {
    let phrase: String
    let beat: CGFloat
    let isPlaying: Bool
    let reduceMotion: Bool
    let onOpenLyrics: () -> Void

    @State private var entryScale: CGFloat = 1
    @State private var entryOpacity: Double = 1
    @State private var animationGeneration = 0

    private let hdrWhite = Color(.displayP3, red: 1.0, green: 0.985, blue: 0.955)
    private let coolHighlight = Color(.displayP3, red: 0.92, green: 0.97, blue: 1.0)

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
        for (wordIndex, word) in words.enumerated() {
            let proposedLength = result[lineIndex].isEmpty
                ? word.count
                : result[lineIndex].count + 1 + word.count
            let remainingWords = words.count - wordIndex
            if lineIndex < targetCount - 1,
               !result[lineIndex].isEmpty,
               proposedLength > targetLength,
               remainingWords >= targetCount - lineIndex {
                lineIndex += 1
            }
            result[lineIndex] += result[lineIndex].isEmpty ? word : " " + word
        }
        return result.filter { !$0.isEmpty }.map { $0.uppercased() }
    }

    private var usesCinematicZoom: Bool {
        phrase.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 10 } == 0
    }

    private var impact: CGFloat {
        guard isPlaying, !reduceMotion else { return 0 }
        let raw = min(max((beat - 0.60) / 0.40, 0), 1)
        return (raw * 5).rounded(.down) / 5
    }

    var body: some View {
        Button(action: onOpenLyrics) {
            ZStack {
                typography(color: hdrWhite.opacity(0.40))
                    .blur(radius: 22)
                    .scaleEffect(1.012)
                    .blendMode(.plusLighter)

                typography(color: hdrWhite)
                    .overlay {
                        typography(color: coolHighlight.opacity(0.16))
                            .blendMode(.plusLighter)
                    }
                    .shadow(color: .black.opacity(0.82), radius: 2, y: 2)
                    .shadow(color: hdrWhite.opacity(0.92), radius: 3)
                    .shadow(color: hdrWhite.opacity(0.34), radius: 16)
            }
            .scaleEffect(entryScale * (1 + impact * 0.022))
            .opacity(entryOpacity)
            .rotationEffect(.degrees(reduceMotion ? 0 : -5.5))
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : 4),
                axis: (x: 1, y: -0.65, z: 0),
                perspective: 0.55
            )
            .offset(x: reduceMotion ? 0 : impact * 4, y: reduceMotion ? 0 : -impact * 2)
            .brightness(Double(impact * 0.10))
            .animation(.linear(duration: 0.055), value: impact)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        animationGeneration += 1
        let generation = animationGeneration
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            entryScale = usesCinematicZoom ? 2.5 : 0.80
            entryOpacity = usesCinematicZoom ? 0.34 : 0.60
        }

        if usesCinematicZoom {
            withAnimation(.easeOut(duration: 0.085)) {
                entryScale = 1
                entryOpacity = 1
            }
            return
        }

        withAnimation(.interpolatingSpring(stiffness: 520, damping: 24)) {
            entryScale = 1.06
            entryOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard generation == animationGeneration else { return }
            withAnimation(.easeOut(duration: 0.10)) {
                entryScale = 1
            }
        }
    }
}
