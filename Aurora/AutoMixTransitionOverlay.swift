import SwiftUI
import UIKit

// MARK: - AutoMix visual hand-off
//
// The incoming cover follows the physical audio hand-off smoothly during AutoMix cross-fading.

struct AutoMixTransitionOverlay: View {
    let player: ActivePlayerPresentation
    let width: CGFloat
    let height: CGFloat

    init(player: ActivePlayerPresentation, width: CGFloat, height: CGFloat) {
        self.player = player
        self.width = width
        self.height = height
    }

    init(player: ActivePlayerPresentation, side: CGFloat) {
        self.init(player: player, width: side, height: side)
    }

    @State private var incomingImage: UIImage?
    @State private var incomingImageTrackId: UUID?

    private var incomingTrack: Track? { player.incomingTrack }

    var body: some View {
        ZStack {
            if player.isTransitionActive, let incomingImage {
                let progress = min(1.0, max(0.0, player.transitionProgress))
                Image(uiImage: incomingImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                    .opacity(progress)
                    .scaleEffect(0.98 + 0.02 * progress)
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
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
