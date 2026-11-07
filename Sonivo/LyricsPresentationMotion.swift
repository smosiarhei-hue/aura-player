import SwiftUI

/// Native compositor transitions: no timers, frame-by-frame view rebuilding or
/// delay in the audio/word clock. ProMotion is enabled in the app's Info.plist;
/// iOS selects the display cadence, capped by the screen and power policy.
///
/// Cover morph uses `matchedGeometryEffect` (Apple Music Now Playing → lyrics).
/// Blurred cover atmosphere stays under the transcript (WWDC26 live-lyrics pipe).
@MainActor enum LyricsPresentationMotion {
    static let coverMorphID = "nowPlayingCover"

    static func animation(reduceMotion: Bool) -> Animation? {
        // Slightly longer than a snap fade so the cover morph reads as one surface.
        reduceMotion ? nil : .smooth(duration: 0.52, extraBounce: 0.02)
    }
    static func controlsAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.30, extraBounce: 0)
    }
    static func transition(reduceMotion: Bool) -> AnyTransition {
        // Opacity only — geometry of the cover is owned by matchedGeometryEffect.
        reduceMotion ? .identity : .opacity
    }
}
