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
text = replace_required(text,
'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                // Ignore end-of-track notifications from replaced (stale) AVPlayerItems
                // so the AutoMix asyncAfter transition and this observer don't double-advance.
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }''',
'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }''', "end notification isolation")
text = replace_required(text,
'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                let message = (notification.object as? AVPlayerItem)?.error?.localizedDescription
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \\($0)" } ?? "Не удалось воспроизвести трек"
            }
        }''',
'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                let message = (notification.object as? AVPlayerItem)?.error?.localizedDescription
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \\($0)" } ?? "Не удалось воспроизвести трек"
            }
        }''', "failure notification isolation")
PLAYER.write_text(text, encoding="utf-8")
print("Swift 6 AVPlayer notification isolation applied.")
