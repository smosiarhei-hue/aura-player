import SwiftUI
import UIKit

/// The menu is installed once. Frequent player/FFT updates only refresh the
/// coordinator's snapshot, never UIButton.menu while a menu is being scrolled.
/// A deferred element rebuilds the items from the latest snapshot on each open.
struct PlayerMoreMenu: UIViewRepresentable {
    enum Action {
        case dislike, trackWave, vibeWave, toggleVideo, generateVideo, regenerateVideo, deleteVideo
        case toggleNeural, lyrics, queue, equalizer, sleepTimer, settings, copyLog, stop
    }

    struct Snapshot {
        var trackID: UUID?
        var disliked: Bool
        var waveAvailable: Bool
        var waveActive: Bool
        var waveLoading: Bool
        var vibeGenerating: Bool
        var videoEnabled: Bool
        var hasVideo: Bool
        var videoGenerating: Bool
        var neuralEnabled: Bool
        var timerText: String?
    }

    var snapshot: Snapshot
    var tint: UIColor
    var perform: (Action, UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(snapshot: snapshot, perform: perform) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)), for: .normal)
        button.tintColor = tint
        button.accessibilityLabel = "Ещё"
        button.showsMenuAsPrimaryAction = true
        let deferred = UIDeferredMenuElement.uncached { [weak coordinator = context.coordinator] completion in
            guard let coordinator else { completion([]); return }
            completion(coordinator.menuItems())
        }
        button.menu = UIMenu(title: "", children: [deferred])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.snapshot = snapshot
        context.coordinator.perform = perform
        if button.tintColor != tint { button.tintColor = tint }
        // Never replace button.menu here: this method runs during playback and
        // replacing it can invalidate the open native menu and its scroll state.
    }

    final class Coordinator {
        var snapshot: Snapshot
        var perform: (Action, UUID?) -> Void
        init(snapshot: Snapshot, perform: @escaping (Action, UUID?) -> Void) {
            self.snapshot = snapshot
            self.perform = perform
        }

        func menuItems() -> [UIMenuElement] {
            let s = snapshot
            let trackID = s.trackID
            func action(_ title: String, _ image: String, _ kind: Action,
                        disabled: Bool = false, destructive: Bool = false,
                        checked: Bool = false, trackSpecific: Bool = false) -> UIAction {
                var attributes: UIMenuElement.Attributes = []
                if disabled { attributes.insert(.disabled) }
                if destructive { attributes.insert(.destructive) }
                return UIAction(title: title, image: image.isEmpty ? nil : UIImage(systemName: image),
                                attributes: attributes, state: checked ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    // A track change while the menu is open must not dislike or
                    // start a wave/video for a different song than the displayed one.
                    if trackSpecific && self.snapshot.trackID != trackID { return }
                    self.perform(kind, trackSpecific ? trackID : nil)
                }
            }
            func section(_ children: [UIMenuElement]) -> UIMenu {
                UIMenu(title: "", options: .displayInline, children: children)
            }

            var sections: [UIMenuElement] = []
            if trackID != nil {
                sections.append(section([
                    action(s.disliked ? "Отменить дизлайк" : "Не рекомендовать этот трек",
                           s.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", .dislike,
                           destructive: !s.disliked, trackSpecific: true)
                ]))
            }
            var media: [UIMenuElement] = [
                action(s.waveLoading ? "Настраиваем волну…" :
                        (s.waveActive ? "Моя волна по треку · активна" : "Моя волна по текущему треку"),
                       s.waveActive ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right", .trackWave,
                       disabled: !s.waveAvailable || s.waveLoading, trackSpecific: true),
                action("AI Вайб-волна (похожие по вайбу)", "sparkles", .vibeWave,
                       disabled: trackID == nil || s.waveLoading || s.vibeGenerating, trackSpecific: true),
                action("Видеошоты", "", .toggleVideo, checked: s.videoEnabled)
            ]
            if s.hasVideo {
                media.append(action("Перегенерировать AI Видео-шот (новый вайб)", "arrow.triangle.2.circlepath", .regenerateVideo,
                                    disabled: trackID == nil || s.videoGenerating, trackSpecific: true))
                media.append(action("Удалить видео-шот", "trash", .deleteVideo, destructive: true, trackSpecific: true))
            } else {
                media.append(action("Создать AI Видео-шот (MiniMax H3)", "sparkles.tv", .generateVideo,
                                    disabled: trackID == nil || s.videoGenerating, trackSpecific: true))
            }
            sections.append(section(media))
            sections.append(section([
                action(s.neuralEnabled ? "Neural Engine: Включён" : "Neural Engine: Выключен",
                       s.neuralEnabled ? "brain.fill" : "brain", .toggleNeural)
            ]))
            sections.append(section([
                action("Текст песни", "quote.bubble", .lyrics),
                action("Очередь", "list.bullet", .queue),
                action("Эквалайзер", "slider.vertical.3", .equalizer),
                action(s.timerText.map { "Таймер сна (\($0))" } ?? "Таймер сна",
                       s.timerText == nil ? "moon.zzz" : "moon.zzz.fill", .sleepTimer),
                action("Настройки", "gearshape", .settings)
            ]))
            sections.append(section([
                action("Скопировать лог AutoMix", "doc.on.clipboard", .copyLog),
                action("Остановить и очистить", "stop.fill", .stop, destructive: true)
            ]))
            return sections
        }
    }
}
