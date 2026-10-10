import SwiftUI

/// Animate only the reveal material, not RootView's startup, navigation or playback.
nonisolated struct SonivoLaunchHomeReveal: ViewModifier, Animatable {
    var progress: Double
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @MainActor func body(content: Content) -> some View {
        content.blur(radius: SonivoLaunchMotion.homeRevealBlur(
            progress: progress, reduceMotion: reduceMotion
        ))
    }
}