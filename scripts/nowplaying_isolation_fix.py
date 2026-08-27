from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"
text = PLAYER.read_text(encoding="utf-8")

# MPMediaItemArtwork request handlers are invoked by MediaPlayer on its own
# background accessQueue. Closures formed inside @MainActor PlayerCore inherit
# MainActor isolation, so Swift 6's executor check traps (SIGTRAP) when the
# handler runs off-main. Form them inside a nonisolated helper instead and
# capture only Sendable values (Data, CGSize).

helper = '''    // MPMediaItemArtwork calls its request handler on MediaPlayer's
    // background accessQueue, so the handler must not be MainActor-isolated.
    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let data = image.pngData() ?? Data()
        let size = image.size
        return MPMediaItemArtwork(boundsSize: size) { _ in
            UIImage(data: data) ?? UIImage()
        }
    }

'''
anchor = "    // MARK: - Playback Controls\n"
if helper not in text:
    if anchor not in text:
        print("[patch-skip] " + str("Playback controls anchor was not found") + " - anchor absent or already integrated; skipping this script")
        raise SystemExit(0)
    text = text.replace(anchor, helper + anchor, 1)

old_info = '''        if let image = LibraryStore.cachedArtworkImage(for: track) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else if let image = remoteArtworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }'''
new_info = '''        if let image = LibraryStore.cachedArtworkImage(for: track) {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        } else if let image = remoteArtworkCache[track.id] {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)
        }'''
if old_info not in text and new_info not in text:
    print("[patch-skip] " + str("Now Playing info artwork block was not found") + " - anchor absent or already integrated; skipping this script")
    raise SystemExit(0)
text = text.replace(old_info, new_info)

old_remote = '''                current[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }'''
new_remote = '''                current[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: image)'''
if old_remote not in text and new_remote not in text:
    print("[patch-skip] " + str("Remote artwork block was not found") + " - anchor absent or already integrated; skipping this script")
    raise SystemExit(0)
text = text.replace(old_remote, new_remote)

PLAYER.write_text(text, encoding="utf-8")
print("Now Playing artwork isolation fix applied.")
