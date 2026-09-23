import SwiftUI
import AVFoundation

/// Full-screen HDR beat-reactive video background for «Моя Волна» on the Home Screen.
/// Plays the 60fps crystalline wave loop without borders or containers, pulsing dynamically to the beat.
struct MyWaveBackgroundVideoView: View {
    let isPlaying: Bool
    var topOffset: CGFloat = 0
    var tintColors: [Color]? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spectrum = SpectrumAnalyzer.shared

    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    private var interval: TimeInterval { 1.0 / 60.0 }

    private var primaryTint: Color {
        if let colors = tintColors, let first = colors.first {
            return first
        }
        return Color.cyan
    }

    private var secondaryTint: Color {
        if let colors = tintColors, colors.count > 1 {
            return colors[1]
        }
        return Color.purple
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let kick = isPlaying && !reduceMotion ? Double(spectrum.kick) : 0
            let bass = isPlaying && !reduceMotion ? Double(spectrum.bass) : 0
            let energy = min(1.0, max(kick, bass * 0.75))

            // Pulse to the beat when playing, or slow ambient breathing when idle
            let beatScale: CGFloat = isPlaying
                ? 1.0 + CGFloat(energy) * 0.075
                : 1.0 + CGFloat(sin(time * 1.4)) * 0.012

            let glowAlpha: Double = isPlaying
                ? 0.25 + energy * 0.55
                : 0.18

            ZStack {
                Color.black.ignoresSafeArea()

                // Native Hardware Video Player (HEVC 60fps)
                if let player {
                    VideoShotPlayerView(player: player, videoGravity: .resizeAspectFill)
                        .scaleEffect(beatScale)
                        .animation(.linear(duration: 0.045), value: beatScale)
                        .clipped()
                }

                // Native HDR EDR Luminous Highlights (Additive glow on peaks)
                RadialGradient(
                    colors: [
                        Color.white.exposureAdjust(2.2 + energy * 1.8)
                            .headroom(3.5 + energy * 3.0)
                            .opacity(glowAlpha),
                        primaryTint.exposureAdjust(1.8 + energy * 1.4)
                            .headroom(2.5 + energy * 2.0)
                            .opacity(glowAlpha * 0.65),
                        secondaryTint.opacity(glowAlpha * 0.25),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 280 + CGFloat(energy) * 90
                )
                .scaleEffect(beatScale)
                .blendMode(.plusLighter)
                .drawingGroup(opaque: false, colorMode: .extendedLinear)
                .allowsHitTesting(false)

                // Smooth bottom vignette into pure OLED black for scrollable feed
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: 0.55),
                        .init(color: .black.opacity(0.40), location: 0.75),
                        .init(color: .black.opacity(0.85), location: 0.90),
                        .init(color: .black, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .allowedDynamicRange(.high)
        }
        .onAppear { setupPlayer() }
        .onDisappear { teardownPlayer() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                player?.play()
            } else {
                player?.pause()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func setupPlayer() {
        guard player == nil else {
            player?.play()
            return
        }

        guard let url = Bundle.main.url(forResource: "my_wave_loop", withExtension: "mp4") else {
            return
        }

        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = []
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.volume = 0
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false

        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        player = queuePlayer
        queuePlayer.play()
    }

    private func teardownPlayer() {
        looper?.disableLooping()
        player?.pause()
        looper = nil
        player = nil
    }
}
