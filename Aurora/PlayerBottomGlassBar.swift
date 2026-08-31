import SwiftUI

/// Fixed native Liquid Glass controls for iOS 26 and newer.
struct PlayerBottomGlassBar: View {
    @State private var player = PlayerCore.shared

    let onLyrics: () -> Void
    let onQueue: () -> Void
    let onEqualizer: () -> Void
    let onSleepTimer: () -> Void
    let onTrackWave: () -> Void
    let onSettings: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                transportButton("backward.fill", label: "Предыдущий трек") {
                    PlaybackAudioSessionCoordinator.shared.activateForPlayback()
                    player.previous()
                }

                Button {
                    PlaybackAudioSessionCoordinator.shared.activateForPlayback()
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .bold))
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")

                transportButton("forward.fill", label: "Следующий трек") {
                    PlaybackAudioSessionCoordinator.shared.activateForPlayback()
                    player.next()
                }

                Menu {
                    Button {
                        player.transitionMode = player.transitionMode == .automix ? .off : .automix
                    } label: {
                        Label(
                            player.transitionMode == .automix ? "Выключить AutoMix" : "Включить AutoMix",
                            systemImage: player.transitionMode == .automix ? "checkmark.circle.fill" : "waveform.path.ecg"
                        )
                    }
                    Button(action: onLyrics) { Label("Текст песни", systemImage: "quote.bubble") }
                    Button(action: onQueue) { Label("Очередь", systemImage: "list.bullet") }
                    Button(action: onEqualizer) { Label("Эквалайзер", systemImage: "slider.vertical.3") }
                    Button(action: onSleepTimer) { Label("Таймер сна", systemImage: "timer") }
                    Button(action: onTrackWave) { Label("Волна по песне", systemImage: "sparkles") }
                    Divider()
                    Button(action: onSettings) { Label("Настройки", systemImage: "gearshape") }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Настройки плеера")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func transportButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .bold))
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }
}
