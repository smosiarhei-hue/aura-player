import SwiftUI

/// Full-screen native zoom presentation. iOS owns the interactive swipe dismissal.
/// Kept in the historical presentation file; this no longer configures a sheet/detent.
struct PlayerFullscreenPresentation: ViewModifier {
    let sourceID: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
    }
}
