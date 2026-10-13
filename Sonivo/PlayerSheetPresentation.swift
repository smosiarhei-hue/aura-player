import SwiftUI

/// System interactive sheet owns dismissal, inertia, cancellation and scroll handoff.
struct PlayerSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        content
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden) // Player header already has its own visual handle.
            .presentationCornerRadius(32)
            .presentationContentInteraction(.resizes)
            .interactiveDismissDisabled(false)
    }
}
