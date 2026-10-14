import SwiftUI

/// Nonvisual lifecycle observation only. Never adds an in-app bar or alters safe areas.
struct SonivoLiveActivityLifecycle: ViewModifier {
    @AppStorage(SonivoLiveActivityController.enabledKey) private var enabled = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var theme = ThemeFontManager.shared
    @State private var icons = AppIconManager.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: theme.selectedTheme) { _, _ in SonivoLiveActivityController.shared.refresh() }
            .onChange(of: icons.selected) { _, _ in SonivoLiveActivityController.shared.refresh() }
            .onChange(of: enabled) { _, _ in SonivoLiveActivityController.shared.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { SonivoLiveActivityController.shared.refresh() }
            }
            .onAppear { SonivoLiveActivityController.shared.refresh() }
    }
}
