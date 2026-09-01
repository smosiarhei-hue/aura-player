"""Stop the artwork tap from skipping tracks, and repair the video shot.

1. The artwork paging gesture used minimumDistance: 12 with only a 1:1
   horizontal check, which is well inside normal finger travel for a tap, so
   tapping the cover frequently skipped a track.
2. VideoShotPlayerView built AVQueuePlayer(url:) and then attached an
   AVPlayerLooper to it. AVPlayerLooper requires an empty queue; with a
   pre-loaded item the loop is undefined and usually nothing plays at all.
   automaticallyWaitsToMinimizeStalling was also disabled, which starts network
   video before it has buffered.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(label + ": required source anchor was not found")
    return text.replace(old, new, 1)


screen = SCREEN.read_text(encoding="utf-8")

# 1. Deliberate paging: require real sideways travel before moving the artwork.
screen = replace_required(
    screen,
    r'''                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { val in
                            if abs(val.translation.width) > abs(val.translation.height) {
                                coverDragX = val.translation.width * 0.60
                            }
                        }
                        .onEnded { val in
                            let threshold: CGFloat = 45
                            if val.translation.width < -threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = -side }
                                nextTrack()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { coverDragX = 0 }
                            } else if val.translation.width > threshold {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = side }
                                previousTrack()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { coverDragX = 0 }
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = 0 }
                            }
                        }
                )
''',
    r'''                .gesture(
                    // A tap, or a swipe that is not clearly sideways, must never
                    // change the track. 44 pt of horizontal travel with a 2.5x
                    // dominance check matches the stock Music app.
                    DragGesture(minimumDistance: 44)
                        .onChanged { val in
                            let horizontal = val.translation.width
                            let vertical = val.translation.height
                            guard abs(horizontal) >= 44,
                                  abs(horizontal) > abs(vertical) * 2.5 else {
                                if coverDragX != 0 {
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { coverDragX = 0 }
                                }
                                return
                            }
                            // Subtract the activation distance so the cover picks
                            // up from the finger without jumping.
                            let travelled = horizontal - (horizontal < 0 ? -44 : 44)
                            coverDragX = travelled * 0.60
                        }
                        .onEnded { val in
                            let horizontal = val.translation.width
                            let vertical = val.translation.height
                            let threshold = max(side * 0.32, 70)

                            guard abs(horizontal) >= 44,
                                  abs(horizontal) > abs(vertical) * 2.5 else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = 0 }
                                return
                            }

                            let predicted = val.predictedEndTranslation.width
                            let shouldPage = abs(horizontal) > threshold || abs(predicted) > side * 0.60
                            guard shouldPage else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = 0 }
                                return
                            }

                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if horizontal < 0 {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = -side }
                                nextTrack()
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) { coverDragX = side }
                                previousTrack()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { coverDragX = 0 }
                        }
                )
''',
    "deliberate artwork paging",
)

# 2. Repair the looping video shot canvas.
screen = replace_required(
    screen,
    r'''    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVQueuePlayer(url: url)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        context.coordinator.looper = looper
        context.coordinator.player = player
        context.coordinator.url = url

        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        controller.view.backgroundColor = .clear
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            let player = AVQueuePlayer(url: url)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = false
            player.actionAtItemEnd = .none
            let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            context.coordinator.looper = looper
            context.coordinator.player = player
            uiViewController.player = player
            player.play()
        }
    }
''',
    r'''    // AVPlayerLooper requires an EMPTY AVQueuePlayer. Handing it a player that
    // was already built with AVQueuePlayer(url:) leaves the loop undefined and
    // in practice nothing shows up at all.
    private static func makeLoopingPlayer(url: URL) -> (AVQueuePlayer, AVPlayerLooper) {
        let player = AVQueuePlayer()
        player.isMuted = true
        // Network video must be allowed to buffer, otherwise it starts before
        // there is anything to show.
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses

        let template = AVPlayerItem(url: url)
        template.preferredMaximumResolution = CGSize(width: 720, height: 1280)
        template.preferredPeakBitRate = 2_500_000
        let looper = AVPlayerLooper(player: player, templateItem: template)
        return (player, looper)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let (player, looper) = Self.makeLoopingPlayer(url: url)
        context.coordinator.looper = looper
        context.coordinator.player = player
        context.coordinator.url = url

        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.updatesNowPlayingInfoCenter = false
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            let (player, looper) = Self.makeLoopingPlayer(url: url)
            context.coordinator.looper = looper
            context.coordinator.player = player
            uiViewController.player = player
            player.play()
        }
    }

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper?.disableLooping()
        uiViewController.player = nil
    }
''',
    "looping video shot canvas",
)

SCREEN.write_text(screen, encoding="utf-8")
print("Player UX fixes applied.")
