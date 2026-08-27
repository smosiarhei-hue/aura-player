from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
text = PLAYER.read_text(encoding="utf-8")

# Temporary stability measure: MediaPlayer serializes MPMediaItemArtwork on its
# background accessQueue, and on iOS 27 beta this path has proven fragile under
# Swift 6 executor checks. Publish Now Playing metadata without artwork until
# the artwork path is re-validated. Metadata (title/artist/duration) remains.
old_info = '''        if let image = LibraryStore.cachedArtworkImage(for: track) {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        } else if let image = remoteArtworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        }'''
new_info = '''        // Artwork intentionally omitted from Now Playing info for stability.'''
if new_info not in text:
    if old_info not in text:
        print("[patch-skip] " + str("Now Playing artwork info block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(old_info, new_info)

old_remote = '''                self.remoteArtworkCache[track.id] = image
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current'''
new_remote = '''                self.remoteArtworkCache[track.id] = image'''
if new_remote not in text:
    if old_remote not in text:
        print("[patch-skip] " + str("Remote artwork publish block was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(old_remote, new_remote)

PLAYER.write_text(text, encoding="utf-8")
print("Now Playing artwork disabled for stability.")
