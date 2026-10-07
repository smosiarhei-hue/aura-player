import SwiftUI
import UIKit

/// Only the visualization. Display-link scheduling and physics stay outside SwiftUI updates.
struct MusicWaveBackground: View {
    let colors: [Color] // Call-site compatibility; approved visualization has its own Sonivo palette.
    let isPlaying: Bool
    let isVisible: Bool
    @State private var isOnScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    private var running: Bool { isOnScreen && isPlaying && isVisible && !reduceMotion && scenePhase == .active }

    var body: some View {
        BeatWaveMetalView(darkMode: colorScheme == .dark,running: running,lowPower: lowPower)
            // Edge feathering is already in Metal; avoid a blurred offscreen SwiftUI mask.
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onAppear { isOnScreen=true }
            .onDisappear { isOnScreen=false }
    }
}
