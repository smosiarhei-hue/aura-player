import SwiftUI

/// Battery-friendly vintage emerald karaoke rendered transparently over artwork/video.
struct KineticLyricsArtwork: View {
    let phrase: String
    let highlightedWordCount: Int
    let reduceMotion: Bool
    let onOpenLyrics: () -> Void

    @State private var opacity: Double = 1
    @State private var tracking: CGFloat = 5
    @State private var entryScale: CGFloat = 1
    @State private var vocalPulse: CGFloat = 1
    @State private var animationGeneration = 0

    private let emerald = Color(red: 0.204, green: 0.827, blue: 0.600)
    private let emeraldDeep = Color(red: 0.039, green: 0.294, blue: 0.153)
    private let milk = Color(red: 0.945, green: 0.961, blue: 0.976)

    private var words: [String] {
        phrase
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).uppercased() }
    }

    private var karaokeText: Text {
        words.enumerated().reduce(Text("")) { result, pair in
            let prefix = pair.offset == 0 ? "" : " "
            let color = pair.offset < highlightedWordCount ? emerald : milk.opacity(0.84)
            return result + Text(prefix + pair.element).foregroundColor(color)
        }
    }

    var body: some View {
        Button(action: onOpenLyrics) {
            ZStack {
                Text(phrase.uppercased())
                    .font(.custom("Baskerville-Bold", size: 72))
                    .tracking(10)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(emeraldDeep.opacity(0.16))
                    .lineLimit(2)
                    .minimumScaleFactor(0.35)
                    .scaleEffect(1.12)
                    .blur(radius: 5)
                    .accessibilityHidden(true)

                karaokeText
                    .font(.custom("Baskerville-Bold", size: 34))
                    .tracking(tracking)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.48)
                    .shadow(color: .black.opacity(0.88), radius: 2, y: 1)
                    .shadow(color: emerald.opacity(0.78), radius: 4)
                    .shadow(color: emerald.opacity(0.24), radius: 16)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(opacity)
            .scaleEffect(entryScale * vocalPulse)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .clipped()
        .accessibilityLabel(phrase)
        .accessibilityHint("Открывает полный текст песни")
        .onAppear(perform: animateLineEntry)
        .onChange(of: phrase) { _, _ in animateLineEntry() }
        .onChange(of: highlightedWordCount) { _, _ in animateVocalPulse() }
    }

    private func animateLineEntry() {
        guard !reduceMotion else {
            opacity = 1
            tracking = 5
            entryScale = 1
            return
        }
        animationGeneration += 1
        let generation = animationGeneration
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            opacity = 0
            tracking = 11
            entryScale = 1.03
        }
        withAnimation(.easeOut(duration: 0.36)) {
            opacity = 1
            tracking = 5
            entryScale = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            guard generation == animationGeneration else { return }
            opacity = 1
            tracking = 5
            entryScale = 1
        }
    }

    private func animateVocalPulse() {
        guard !reduceMotion else { return }
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) { vocalPulse = 1.018 }
        withAnimation(.easeOut(duration: 0.20)) { vocalPulse = 1 }
    }
}
