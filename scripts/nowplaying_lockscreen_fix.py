from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


text = PLAYER.read_text(encoding="utf-8")

# 1. MediaPlayer needs an explicit playback state before iOS treats this app as
#    the Now Playing app. Without it the lock screen and Dynamic Island show
#    controls that work, but tapping them does not open the app.
text = replace_required(
    text,
    "        MPNowPlayingInfoCenter.default().nowPlayingInfo = info\n",
    """        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
""",
    "Now Playing playback state",
)

# 2. MediaPlayer asks for a specific size. Returning one fixed oversized image
#    is why the artwork often stayed blank; draw the requested size instead.
text = replace_required(
    text,
    """    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let data = image.pngData() ?? Data()
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(data: data) ?? UIImage()
        }
    }""",
    """    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        // Downscale once so the handler stays cheap, then satisfy each request
        // at exactly the size MediaPlayer asked for.
        let maxSide: CGFloat = 600
        let source: UIImage
        if max(image.size.width, image.size.height) > maxSide, image.size.width > 0, image.size.height > 0 {
            let scale = maxSide / max(image.size.width, image.size.height)
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: target)
            source = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        } else {
            source = image
        }

        let data = source.jpegData(compressionQuality: 0.9) ?? source.pngData() ?? Data()
        let baseSize = source.size

        return MPMediaItemArtwork(boundsSize: baseSize) { requestedSize in
            guard let decoded = UIImage(data: data) else { return UIImage() }
            guard requestedSize.width > 0, requestedSize.height > 0 else { return decoded }

            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: requestedSize, format: format)
            return renderer.image { _ in
                decoded.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
    }""",
    "resizable Now Playing artwork",
)

# 3. Publish artwork as soon as a track is selected, not only after the first
#    progress tick, so the lock screen is never left without a cover.
text = replace_required(
    text,
    """        if let cover = track.coverURL, let url = URL(string: cover),
           LibraryStore.cachedArtworkImage(for: track) == nil,
           remoteArtworkCache[track.id] == nil {""",
    """        if let cover = track.coverURL, let url = URL(string: cover),
           LibraryStore.cachedArtworkImage(for: track) == nil,
           remoteArtworkCache[track.id] == nil,
           !pendingArtworkFetches.contains(track.id) {
            pendingArtworkFetches.insert(track.id)""",
    "single-flight artwork fetch",
)
text = replace_required(
    text,
    """            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                guard let self, self.currentTrack?.id == track.id else { return }
                self.remoteArtworkCache[track.id] = image""",
    """            Task { [weak self] in
                defer { Task { @MainActor [weak self] in self?.pendingArtworkFetches.remove(track.id) } }
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                guard let self, self.currentTrack?.id == track.id else { return }
                self.remoteArtworkCache[track.id] = image""",
    "artwork fetch bookkeeping",
)
text = replace_required(
    text,
    "    private var remoteArtworkCache: [UUID: UIImage] = [:]\n",
    """    private var remoteArtworkCache: [UUID: UIImage] = [:]
    private var pendingArtworkFetches: Set<UUID> = []
""",
    "artwork fetch state",
)

# 4. Keep the widget in sync when a track is chosen and when playback stops.
text = replace_required(
    text,
    """        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return""",
    """        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return""",
    "stopped playback state",
)

PLAYER.write_text(text, encoding="utf-8")
print("Lock screen artwork and tap-to-open Now Playing fixes applied.")
