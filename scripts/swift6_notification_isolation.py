from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "Aurora" / "playercore.swift"


def replace_required_any(text, candidates, new, label):
    if new in text:
        return text
    for old in candidates:
        if old in text:
            return text.replace(old, new, 1)
    raise RuntimeError(f"{label}: required source anchor was not found")


text = PLAYER.read_text(encoding="utf-8")

end_task_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
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

end_assume_isolated_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                if let item = notification.object as? AVPlayerItem, item !== self.streamingPlayer.currentItem {
                    return
                }
                self.handleTrackFinish()
            }
        }'''

end_safe_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                // AutoMix transition guards prevent stale end notifications
                // from advancing the queue more than once.
                self.handleTrackFinish()
            }
        }'''

text = replace_required_any(
    text,
    [end_task_observer, end_assume_isolated_observer],
    end_safe_observer,
    "end notification isolation",
)

failure_task_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
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

failure_assume_isolated_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
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

failure_safe_observer = r'''        NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUsingStreamPlayer else { return }
                let message = self.streamingPlayer.currentItem?.error?.localizedDescription
                self.isPlaying = false
                self.playError = message.map { "Ошибка потока: \($0)" } ?? "Не удалось воспроизвести трек"
            }
        }'''

text = replace_required_any(
    text,
    [failure_task_observer, failure_assume_isolated_observer],
    failure_safe_observer,
    "failure notification isolation",
)

PLAYER.write_text(text, encoding="utf-8")
print("Swift 6 AVPlayer notification isolation applied.")
