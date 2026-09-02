import SwiftUI
import UIKit

// MARK: - AutoMix visual hand-off
//
// A real cover-to-cover "show": the incoming track's artwork rises from
// underneath the outgoing one while a soft full-frame HDR-white bloom peaks
// at the midpoint of the blend, synced with the actual DSP blend progress
// (dj.transitionProgress) - not a fixed-length animation of its own, and not
// a moving diagonal line/band. Mounted directly over the artwork stage, so
// it can never cover the transport controls or the timeline below it.

struct AutoMixTransitionOverlay: View {
    @State private var player = PlayerCore.shared
    @State private var dj = AutoMixDJEngine.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches the square side of the artwork stage this overlay sits on top of.
    let side: CGFloat

    @State private var incomingImage: UIImage?
    @State private var incomingImageTrackId: UUID?

    private var outgoingPalette: [Color] {
        let values = player.currentTrack?.palette ?? []
        return values.isEmpty ? [AG.amber, AG.ember] : values
    }

    /// The actual track AutoMix is blending into, read straight from
    /// PlayerCore. This used to be guessed from queue position, which
    /// silently disagreed with the real pick whenever shuffle or a Wave
    /// queue refill was active - the cover crossfade below then had nothing
    /// (or the wrong artwork) to show and only the light sweep was visible.
    private var incomingTrack: Track? { player.incomingTrack }

    var body: some View {
        ZStack {
            if dj.isTransitionActive {
                transitionContent
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        // Top-5 fix #2 (screen-recording analysis, [00:11.2]): preload and
        // fully pre-decode the incoming cover the moment AutoMix picks it -
        // many seconds before the crossfade's first frame - instead of only
        // starting the moment the blend becomes active. This `.task` is
        // attached to the always-mounted container above (not gated behind
        // `dj.isTransitionActive`), so decoding never lands on the frame
        // that kicks off the visible blend, which previously produced a
        // ~160 ms / 2-3 frame stall.
        .task(id: incomingTrack?.id) {
            await loadIncomingImage()
        }
    }

    @ViewBuilder
    private var transitionContent: some View {
        let progress = min(1, max(0, dj.transitionProgress))
        ZStack {
            // The incoming cover rises underneath the outgoing artwork as the
            // blend advances, so the hand-off actually reads as cover-to-cover.
            if let incomingImage {
                Image(uiImage: incomingImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .opacity(progress)
                    .scaleEffect(0.97 + 0.03 * progress)
            }

            // Premium HDR hand-off: a soft, full-frame white bloom that
            // breathes in and back out right at the midpoint of the blend,
            // instead of a moving line/band sweeping across the cover.
            // Reads as one clean flash of light, not a running stripe.
            if !reduceMotion {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
                    .opacity(bloomIntensity(progress) * 0.85)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }

            RadialGradient(
                colors: [
                    .white.opacity(bloomIntensity(progress) * 0.40),
                    (outgoingPalette.first ?? AG.amber).opacity(bloomIntensity(progress) * 0.25),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: side * 0.75
            )
            .blendMode(.screen)
            .allowsHitTesting(false)
        }
    }

    /// Local files already have a cached artwork file the moment they are
    /// queued. Streamed tracks (the common case) do not - their cover is
    /// only ever fetched lazily by an AsyncImage elsewhere - so without this,
    /// the crossfade above had no image to show for almost every real
    /// AutoMix transition. Downloading it once here, well before the blend
    /// actually starts (AutoMix picks its target track many seconds ahead),
    /// gives the crossfade something real to show every time. The decode
    /// itself is then forced fully off the main thread and finished ahead of
    /// time via `byPreparingForDisplay()`, so nothing decodes on the frame
    /// that kicks off the visible blend.
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

    private func bloomIntensity(_ progress: Double) -> Double {
        let distance = abs(progress - 0.5) / 0.30
        return max(0, 1 - distance * distance)
    }
}
