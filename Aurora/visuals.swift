import SwiftUI

// MARK: - Fullscreen Animated Liquid Mesh Background (Apple Music Style)

struct AnimatedMeshBackground: View {
    let palette: [Color]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let w = Double(size.width)
                let h = Double(size.height)

                let colors = palette.isEmpty ? [Color.teal, Color.indigo, Color.purple] : palette

                for i in 0..<6 {
                    let fi = Double(i)
                    let speed = 0.08 + 0.03 * (fi.truncatingRemainder(dividingBy: 3))
                    let phase = fi * 1.05 + t * speed
                    let cx = w * (0.5 + 0.38 * sin(phase + fi * 0.7))
                    let cy = h * (0.5 + 0.35 * cos(phase * 0.8 + fi * 1.2))
                    let r = min(w, h) * (0.35 + 0.08 * sin(t * 0.5 + fi * 1.8))

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

// MARK: - Track Artwork View with Play/Pause Spring Scaling

struct TrackArtworkView: View {
    let track: Track?
    let isPlaying: Bool
    var size: CGFloat = 300

    var body: some View {
        Group {
            if let track = track, let img = LibraryStore.cachedArtworkImage(for: track) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let track = track, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        artworkPlaceholder
                    }
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: isPlaying ? 24 : 12, x: 0, y: isPlaying ? 16 : 8)
        .scaleEffect(isPlaying ? 1.0 : 0.88)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isPlaying)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: track?.palette ?? Palette.seeded(42).colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
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
            } else if let track = track, let cover = track.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
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

// MARK: - 32-Band Live Spectrum Analyzer Bars

struct SpectrumView: View {
    @State private var analyzer = SpectrumAnalyzer.shared
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 48

    var body: some View {
        GeometryReader { geo in
            let count = SpectrumAnalyzer.bandCount
            let spacing = max(2, (geo.size.width - CGFloat(count) * barWidth) / CGFloat(max(count - 1, 1)))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    SettingsStore.shared.accentColor,
                                    SettingsStore.shared.accent.colors.last ?? .teal
                                ],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: barWidth, height: max(3, CGFloat(analyzer.bands[i]) * maxHeight))
                }
            }
            .frame(width: geo.size.width, height: maxHeight, alignment: .bottom)
        }
        .frame(height: maxHeight)
    }
}
