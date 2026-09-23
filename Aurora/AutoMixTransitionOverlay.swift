import SwiftUI
import UIKit

// MARK: - AutoMix visual hand-off
//
// The incoming cover follows the physical audio hand-off. A separate thin
// Liquid Glass contour remains attached to the committed/audible track and is
// driven by the main mixer's live spectrum.

struct AutoMixTransitionOverlay: View {
    let player: ActivePlayerPresentation
    let side: CGFloat

    @State private var incomingImage: UIImage?
    @State private var incomingImageTrackId: UUID?

    private var incomingTrack: Track? { player.incomingTrack }
    private var borderPalette: [Color] {
        let colors = player.displayTrack?.palette ?? []
        return colors.isEmpty ? [.cyan, .blue] : colors
    }

    var body: some View {
        ZStack {
            if player.isTransitionActive, let incomingImage {
                let progress = min(1.0, max(0.0, player.transitionProgress))
                Image(uiImage: incomingImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .opacity(progress)
                    .scaleEffect(0.98 + 0.02 * progress)
                    .transition(.opacity)
            }

            MusicReactiveLiquidBorder(
                player: player,
                cornerRadius: 24,
                palette: borderPalette
            )
            .frame(width: side, height: side)
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .task(id: incomingTrack?.id) {
            await loadIncomingImage()
        }
    }

    private func loadIncomingImage() async {
        guard let incomingTrack else {
            incomingImage = nil
            incomingImageTrackId = nil
            return
        }
        guard incomingImageTrackId != incomingTrack.id else { return }

        var rawImage: UIImage?
        if let cached = LibraryStore.cachedArtworkImage(for: incomingTrack) {
            rawImage = cached
        } else if let cover = incomingTrack.coverURL, let url = URL(string: cover) {
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                rawImage = UIImage(data: data)
            }
        }

        guard let rawImage else {
            incomingImage = nil
            incomingImageTrackId = incomingTrack.id
            return
        }

        let decoded = await rawImage.byPreparingForDisplay()
        guard player.incomingTrack?.id == incomingTrack.id else { return }
        incomingImageTrackId = incomingTrack.id
        incomingImage = decoded ?? rawImage
    }
}
