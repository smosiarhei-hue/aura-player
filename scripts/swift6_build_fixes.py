from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AURORA = ROOT / "Aurora"

player_screen = AURORA / "PlayerScreenV2.swift"
text = player_screen.read_text()
old_opacity = ".opacity(1 - min(max(dragY, 0) / 650, 0.22))"
new_opacity = ".opacity(1 - Double(min(max(dragY, CGFloat.zero) / CGFloat(650), CGFloat(0.22))))"
if old_opacity not in text and new_opacity not in text:
    raise RuntimeError("Player opacity expression was not found")
text = text.replace(old_opacity, new_opacity)
player_screen.write_text(text)

library = AURORA / "librarystore.swift"
text = library.read_text()
old_helper = '''            func first(_ id: AVMetadataIdentifier) -> String? {
                AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first?.stringValue
            }
            if let t = first(.commonIdentifierTitle), !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }
            if let a = first(.commonIdentifierArtist), !a.trimmingCharacters(in: .whitespaces).isEmpty { artist = a }
            if let alb = first(.commonIdentifierAlbumName), !alb.trimmingCharacters(in: .whitespaces).isEmpty { album = alb }

            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = item.dataValue, let image = UIImage(data: data) {'''
new_helper = '''            func first(_ id: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first else {
                    return nil
                }
                return try? await item.load(.stringValue)
            }
            if let t = await first(.commonIdentifierTitle), !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }
            if let a = await first(.commonIdentifierArtist), !a.trimmingCharacters(in: .whitespaces).isEmpty { artist = a }
            if let alb = await first(.commonIdentifierAlbumName), !alb.trimmingCharacters(in: .whitespaces).isEmpty { album = alb }

            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await item.load(.dataValue),
               let image = UIImage(data: data) {'''
if old_helper not in text and new_helper not in text:
    raise RuntimeError("Legacy metadata block was not found")
text = text.replace(old_helper, new_helper)
library.write_text(text)
