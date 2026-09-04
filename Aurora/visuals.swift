import SwiftUI

// MARK: - Fullscreen Animated Liquid Mesh Background (Apple Music Style)

struct AnimatedMeshBackground: View {
    let palette: [Color]
    @State private var analyzer = SpectrumAnalyzer.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let w = Double(size.width)
                let h = Double(size.height)

                let colors = palette.isEmpty ? [Color.teal, Color.indigo, Color.purple] : palette

                // Live audio energy (bass-weighted) pulses the blobs so the
                // backdrop actually breathes with the music instead of just
                // drifting on a fixed, silent sine wave.
                let bands = analyzer.bands
                let bassEnergy: Double = bands.isEmpty ? 0 : {
                    let count = min(6, bands.count)
                    let sum = bands.prefix(count).reduce(Float(0), +)
                    return Double(sum / Float(count))
                }()
                let pulse = 1.0 + min(0.22, bassEnergy * 0.45)

                for i in 0..<6 {
                    let fi = Double(i)
                    let speed = 0.08 + 0.03 * (fi.truncatingRemainder(dividingBy: 3))
                    let phase = fi * 1.05 + t * speed
                    let cx = w * (0.5 + 0.38 * sin(phase + fi * 0.7))
                    let cy = h * (0.5 + 0.35 * cos(phase * 0.8 + fi * 1.2))
                    let r = min(w, h) * (0.35 + 0.08 * sin(t * 0.5 + fi * 1.8)) * pulse

                    let color = colors[i % colors.count]
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

                    ctx.opacity = 0.75
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .blur(radius: 65)
        .scaleEffect(1.3)
        .overlay(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.40),
                    Color.black.opacity(0.75)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }
}

// MARK: - Small Artwork Thumbnail

struct SmallArtwork: View {
    let track: Track?
    let palette: [Color]
    var size: CGFloat = 48

    init(track: Track? = nil, palette: [Color]? = nil, size: CGFloat = 48) {
        self.track = track
        self.palette = palette ?? track?.palette ?? Palette.seeded(1).colors
        self.size = size
    }

    var body: some View {
        Group {
            if let track = track, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else if let track = track, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipped()
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .clipped()
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
