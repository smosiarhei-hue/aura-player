import SwiftUI
import UIKit

// MARK: - AutoMix visual hand-off
//
// Clean, standard Apple Music cover crossfade:
// The incoming track's artwork smoothly dissolves in over the outgoing cover,
// synced 1:1 with audio DSP transition progress without artificial white flashing or blinding bloom.

struct AutoMixTransitionOverlay: View {
    let player: ActivePlayerPresentation
    let side: CGFloat

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
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .opacity(progress)
                    .scaleEffect(0.98 + 0.02 * progress)
                    .transition(.opacity)
            }
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
