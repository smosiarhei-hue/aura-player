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

    private var artworkPagingGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                guard !isPagingArtwork,
                      abs(value.translation.width) > abs(value.translation.height) * 1.15 else { return }
                let width = max(UIScreen.main.bounds.width, 1)
                artworkPageOffset = min(max(value.translation.width, -width), width)
            }
            .onEnded { value in
                guard !isPagingArtwork else { return }
                let width = max(UIScreen.main.bounds.width, 1)
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let shouldPage = abs(horizontal) > width * 0.32 || abs(predicted) > width * 0.55
                guard shouldPage, abs(horizontal) > abs(value.translation.height) else {
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

player = PLAYER.read_text(encoding="utf-8")
player = replace_required(player, "let interval = CMTime(seconds: 0.10, preferredTimescale: 600)", "let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)", "30 Hz stream progress")
player = replace_required(player, "let timer = Timer(timeInterval: 0.10, repeats: true)", "let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true)", "30 Hz local progress")
PLAYER.write_text(player, encoding="utf-8")
print("Interactive artwork paging, tap seeking, and efficient 30 Hz progress applied.")
