"""Make the Lock Screen / Dynamic Island card show artwork and be tappable.

Two separate defects:

1. MPNowPlayingInfoCenter.playbackState was never set. Without it iOS does not
   consider the app the Now Playing app, so the transport buttons work but
   tapping the card does not open the app.
2. nowPlayingArtwork ignored the size the system asked for and handed back one
   large PNG-decoded image, so the artwork often failed to appear.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(label + ": required source anchor was not found")
    return text.replace(old, new, 1)


player = PLAYER.read_text(encoding="utf-8")

# 1. Honour the requested artwork size and decode only once.
player = replace_required(
    player,
    r'''    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let data = image.pngData() ?? Data()
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(data: data) ?? UIImage()
        }
    }
''',
    r'''    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        // Downscale once, then render into whatever size the system requests.
        // Returning a single fixed-size image made the Lock Screen and the
        // Dynamic Island silently drop the artwork.
        let maxSide: CGFloat = 600
        let source: UIImage
        let longest = max(image.size.width, image.size.height)
        if longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            source = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        } else {
            source = image
        }

        return MPMediaItemArtwork(boundsSize: source.size) { requestedSize in
            guard requestedSize.width > 0, requestedSize.height > 0 else { return source }
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            return UIGraphicsImageRenderer(size: requestedSize, format: format).image { _ in
                source.draw(in: CGRect(origin: .zero, size: requestedSize))
            }
        }
    }
''',
    "resizable now playing artwork",
)

# 2. Publish playback state so the card opens the app when tapped.
player = replace_required(
    player,
    r'''        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
''',
    r'''        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Without an explicit playback state iOS does not treat this app as the
        // Now Playing app, so tapping the Lock Screen or Dynamic Island card
        // does nothing even though the buttons work.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
''',
    "now playing playback state",
)

player = replace_required(
    player,
    r'''        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
''',
    r'''        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
''',
    "stopped playback state",
)

# 3. Register for remote control events.
player = replace_required(
    player,
    r'''        let commandCenter = MPRemoteCommandCenter.shared()
''',
    r'''        UIApplication.shared.beginReceivingRemoteControlEvents()

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
''',
    "remote control registration",
)

# 4. Repainting the whole Observable player 60-120 times a second is what made
#    the device warm and the UI feel choppy. 30 Hz is smooth for a scrubber.
player = replace_required(
    player,
    "            let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)",
    "            let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)",
    "30 Hz stream progress",
)

player = replace_required(
    player,
    "        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in",
    "        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in",
    "30 Hz local progress",
)

PLAYER.write_text(player, encoding="utf-8")
print("Now Playing widget fixes applied.")
