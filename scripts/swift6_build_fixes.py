from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AURORA = ROOT / "Aurora"

player_screen = AURORA / "PlayerScreenV2.swift"
text = player_screen.read_text(encoding="utf-8")
old_opacity = ".opacity(1 - min(max(dragY, 0) / 650, 0.22))"
new_opacity = ".opacity(1 - Double(min(max(dragY, CGFloat.zero) / CGFloat(650), CGFloat(0.22))))"
if old_opacity not in text and new_opacity not in text:
    print("[patch-skip] " + str("Player opacity expression was not found") + " - anchor absent or already integrated; skipping this script")
    raise SystemExit(0)
text = text.replace(old_opacity, new_opacity)
player_screen.write_text(text, encoding="utf-8")

library = AURORA / "librarystore.swift"
text = library.read_text(encoding="utf-8")
old_helper = r'''            func first(_ id: AVMetadataIdentifier) -> String? {
                AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first?.stringValue
            }
            if let t = first(.commonIdentifierTitle), !t.trimmingCharacters(in: .whitespaces).isEmpty { title = t }
            if let a = first(.commonIdentifierArtist), !a.trimmingCharacters(in: .whitespaces).isEmpty { artist = a }
            if let alb = first(.commonIdentifierAlbumName), !alb.trimmingCharacters(in: .whitespaces).isEmpty { album = alb }

            if let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = item.dataValue, let image = UIImage(data: data) {'''
new_helper = r'''            func first(_ id: AVMetadataIdentifier) async -> String? {
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
    print("[patch-skip] " + str("Legacy metadata block was not found") + " - anchor absent or already integrated; skipping this script")
    raise SystemExit(0)
text = text.replace(old_helper, new_helper)
library.write_text(text, encoding="utf-8")

player = AURORA / "playercore.swift"
text = player.read_text(encoding="utf-8")
old_finished_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                // Ignore end-of-track notifications from replaced (stale) AVPlayerItems
                // so the AutoMix asyncAfter transition and this observer don't double-advance.
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }'''
new_finished_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }'''
text = text.replace(old_finished_observer, new_finished_observer)

old_failed_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                let message = (notification.object as? AVPlayerItem)?.error?.localizedDescription
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \($0)" } ?? "Не удалось воспроизвести трек"
            }
        }'''
new_failed_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                let message = (notification.object as? AVPlayerItem)?.error?.localizedDescription
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \($0)" } ?? "Не удалось воспроизвести трек"
            }
        }'''
text = text.replace(old_failed_observer, new_failed_observer)
player.write_text(text, encoding="utf-8")
