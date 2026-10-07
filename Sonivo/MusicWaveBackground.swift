import SwiftUI
import UIKit

/// Only the visualization. Display-link scheduling and physics stay outside SwiftUI updates.
struct MusicWaveBackground: View {
    let colors: [Color] // Fallback until the current cover has been decoded.
    let track: Track?
    @State private var coverColors: [Color]=[]
    @State private var resolvedCoverKey: String?
    let isPlaying: Bool
    let isVisible: Bool
    @State private var isOnScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    private var running: Bool { isOnScreen && isPlaying && isVisible && !reduceMotion && scenePhase == .active }

    private var coverKey: String { "\(track?.id.uuidString ?? "none")|\(track?.coverURL ?? "")|\(track?.artworkSeed ?? 0)" }
    private var resolvedColors: [Color] { resolvedCoverKey==coverKey && !coverColors.isEmpty ? coverColors : colors }

    var body: some View {
        BeatWaveMetalView(colors: resolvedColors,darkMode: colorScheme == .dark,running: running,lowPower: lowPower)
            // Edge feathering is already in Metal; avoid a blurred offscreen SwiftUI mask.
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .task(id: coverKey) {
                let key=coverKey
                guard let track,let palette=await BeatWaveArtworkPalette.colors(for: track),
                      !Task.isCancelled,coverKey==key else { return }
                coverColors=palette; resolvedCoverKey=key
            }
            .onAppear { isOnScreen=true }
            .onDisappear { isOnScreen=false }
    }
}
