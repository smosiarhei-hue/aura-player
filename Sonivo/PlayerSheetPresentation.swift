import SwiftUI

/// Native full-screen presentation. Only the explicit close control/header drag dismisses.
/// The former whole-screen zoom recognizer could steal artwork and slider gestures.
struct PlayerFullscreenPresentation: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.interactiveDismissDisabled(true)
    }
}
