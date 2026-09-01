from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"
PLAYER = ROOT / "Aurora" / "playercore.swift"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


screen = SCREEN.read_text(encoding="utf-8")
screen = replace_required(screen, '''    @State private var dismissing = false
''', '''    @State private var dismissing = false
    @State private var artworkPageOffset: CGFloat = 0
    @State private var isPagingArtwork = false
''', "artwork paging state")
screen = replace_required(screen, '''                    .frame(width: geo.size.width, alignment: .center)
                    .clipped()''', '''                    .frame(width: geo.size.width, alignment: .center)
                    .offset(x: artworkPageOffset)
                    .clipped()''', "interactive player offset")
screen = replace_required(screen, '''        .interactiveDismissDisabled(dismissing)
''', '''        .interactiveDismissDisabled(dismissing)
        .simultaneousGesture(artworkPagingGesture)
''', "artwork paging gesture")
screen = replace_required(screen, '''            )
            .tint(.white)

            HStack {''', '''            )
            .tint(.white)
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    let usableWidth = max(UIScreen.main.bounds.width - 44, 1)
                    let fraction = min(max(value.location.x / usableWidth, 0), 1)
                    player.seek(to: player.duration * Double(fraction))
                }
            )

            HStack {''', "tap to seek")
screen = replace_required(screen, '''    // MARK: Actions
''', '''    // MARK: Artwork paging

    // A tap, or a swipe that is mostly vertical, must never change the track.
    // Paging only starts once the finger has clearly travelled sideways, which
    // matches how the stock Music app behaves.
    private static let artworkPageActivation: CGFloat = 44

    private var artworkPagingGesture: some Gesture {
        DragGesture(minimumDistance: Self.artworkPageActivation, coordinateSpace: .local)
            .onChanged { value in
                guard !isPagingArtwork else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) >= Self.artworkPageActivation,
                      abs(horizontal) > abs(vertical) * 2.5 else {
                    if artworkPageOffset != 0 {
                        withAnimation(.smooth(duration: 0.20)) { artworkPageOffset = 0 }
                    }
                    return
                }
                let width = max(UIScreen.main.bounds.width, 1)
                // Subtract the activation distance so the artwork starts moving
                // from where the swipe was recognised, with no visual jump.
                let travelled = horizontal - (horizontal < 0 ? -Self.artworkPageActivation : Self.artworkPageActivation)
                artworkPageOffset = min(max(travelled, -width), width)
            }
            .onEnded { value in
                guard !isPagingArtwork else { return }
                let width = max(UIScreen.main.bounds.width, 1)
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width

                guard abs(horizontal) >= Self.artworkPageActivation,
                      abs(horizontal) > abs(value.translation.height) * 2.5 else {
                    withAnimation(.smooth(duration: 0.24)) { artworkPageOffset = 0 }
                    return
                }

                let shouldPage = abs(horizontal) > width * 0.34 || abs(predicted) > width * 0.62
                guard shouldPage else {
                    withAnimation(.smooth(duration: 0.24)) { artworkPageOffset = 0 }
                    return
                }
                completeArtworkPage(forward: horizontal < 0, width: width)
            }
    }

    private func completeArtworkPage(forward: Bool, width: CGFloat) {
        guard !isPagingArtwork else { return }
        isPagingArtwork = true
        let exitOffset = forward ? -width : width
        withAnimation(.smooth(duration: 0.22)) { artworkPageOffset = exitOffset }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if forward { nextTrack() } else { previousTrack() }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { artworkPageOffset = forward ? width : -width }
            withAnimation(.smooth(duration: 0.28)) { artworkPageOffset = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { isPagingArtwork = false }
        }
    }

    // MARK: Actions
''', "artwork paging implementation")
SCREEN.write_text(screen, encoding="utf-8")

# The stream observer and the local progress timer are both installed at
# 1/60 s and 1/120 s in the current sources. Driving the whole Observable
# PlayerCore that fast repaints the entire player every tick, which is what
# caused the heat and the choppy feel. 30 Hz is smooth for a progress bar.
player = PLAYER.read_text(encoding="utf-8")


def relax_cadence(text: str, candidates, new: str, label: str) -> str:
    if new in text:
        return text
    for old in candidates:
        if old in text:
            return text.replace(old, new, 1)
    raise RuntimeError(f"{label}: required source anchor was not found")


player = relax_cadence(
    player,
    [
        "let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)",
        "let interval = CMTime(seconds: 1.0 / 120.0, preferredTimescale: 600)",
        "let interval = CMTime(seconds: 0.10, preferredTimescale: 600)",
    ],
    "let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)",
    "30 Hz stream progress",
)
player = relax_cadence(
    player,
    [
        "let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true)",
        "let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true)",
        "let timer = Timer(timeInterval: 0.10, repeats: true)",
    ],
    "let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true)",
    "30 Hz local progress",
)
PLAYER.write_text(player, encoding="utf-8")
print("Deliberate artwork paging, tap seeking, and efficient 30 Hz progress applied.")
