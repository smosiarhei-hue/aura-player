import SwiftUI

/// Native compositor transitions: no timers, frame-by-frame view rebuilding or
/// delay in the audio/word clock. ProMotion is enabled in the app's Info.plist;
/// iOS selects the display cadence, capped by the screen and power policy.
@MainActor enum LyricsPresentationMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.38, extraBounce: 0)
    }
    static func controlsAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.30, extraBounce: 0)
    }
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 16))
    }
}
