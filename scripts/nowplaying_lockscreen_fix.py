from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


def replace_optional(text, old, new, label):
    """Best-effort refinement. Never fails the build if the shape changed."""
    if new in text:
        return text, True
    if old not in text:
        print(f"[patch-skip] {label} - anchor absent; skipping this refinement")
        return text, False
    return text.replace(old, new, 1), True


text = PLAYER.read_text(encoding="utf-8")

# 1. iOS only treats an app as "the Now Playing app" - the one the lock screen
#    and Dynamic Island open when tapped - once it publishes an explicit
#    playback state. Without this the controls work but the tap does nothing.
text = replace_required(
    text,
    "        MPNowPlayingInfoCenter.default().nowPlayingInfo = info\n",
    """        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
""",
    "Now Playing playback state",
)

# 2. MediaPlayer requests artwork at a specific size on a background queue.
#    Handing back one fixed oversized PNG is why the cover often stayed blank.
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
        // Downscale once so the handler stays cheap, then answer every request
        // at exactly the size MediaPlayer asked for.
        let maxSide: CGFloat = 600
        let source: UIImage
        if image.size.width > 0, image.size.height > 0,
           max(image.size.width, image.size.height) > maxSide {
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
            guard requestedSize.width > 1, requestedSize.height > 1 else { return decoded }

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

# 3. Optional: stop re-issuing the same remote cover download on every tick.
text, guarded = replace_optional(
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
if guarded:
    text, released = replace_optional(
        text,
        """            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),""",
        """            Task { [weak self] in
                defer { Task { @MainActor [weak self] in self?.pendingArtworkFetches.remove(track.id) } }
                guard let (data, _) = try? await URLSession.shared.data(from: url),""",
        "artwork fetch release",
    )
    if released:
        text = replace_required(
            text,
            "    private var remoteArtworkCache: [UUID: UIImage] = [:]\n",
            """    private var remoteArtworkCache: [UUID: UIImage] = [:]
    private var pendingArtworkFetches: Set<UUID> = []
""",
            "artwork fetch state",
        )
    else:
        raise RuntimeError("artwork fetch release: guard was inserted without a matching release")

PLAYER.write_text(text, encoding="utf-8")
print("Lock screen artwork and tap-to-open Now Playing fixes applied.")
