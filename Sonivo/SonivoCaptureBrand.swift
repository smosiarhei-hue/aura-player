import SwiftUI

/// Real in-app safe-area content, not an imitation of iOS recording controls or camera cutout.
struct SonivoCaptureBrand: ViewModifier {
    static let visibleKey = "appearance.captureBrandVisible"
    @AppStorage(Self.visibleKey) private var alwaysVisible = true
    @AppStorage(SonivoLiveActivityController.enabledKey) private var liveActivityEnabled = true
    @Environment(\.isSceneCaptured) private var isCaptured
    @Environment(\.scenePhase) private var scenePhase
    @State private var theme = ThemeFontManager.shared
    @State private var icons = AppIconManager.shared
    @State private var player = PlayerCore.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if alwaysVisible || isCaptured {
                SonivoCaptureBrandBar(icon: icons.selected ?? .music, color: theme.accentColor,
                                      playing: player.isPlaying)
            }
        }
        .onChange(of: theme.selectedTheme) { _, _ in SonivoLiveActivityController.shared.refresh() }
        .onChange(of: icons.selected) { _, _ in SonivoLiveActivityController.shared.refresh() }
        .onChange(of: liveActivityEnabled) { _, _ in SonivoLiveActivityController.shared.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { SonivoLiveActivityController.shared.refresh() }
        }
        .onAppear { SonivoLiveActivityController.shared.refresh() }
    }
}

private struct SonivoCaptureBrandBar: View {
    let icon: SonivoAppIcon
    let color: Color
    let playing: Bool
    private var key: String {
        switch icon {
        case .signature: "signature"
        case .wordmark: "wordmark"
        case .classic: "classic"
        default: "music"
        }
    }
    var body: some View {
        HStack(spacing: 9) {
            SonivoBrandGlyph(icon: key, size: 40, color: color)
            Text("Sonivo").font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Spacer()
            if playing { SonivoBrandWave(color: color).scaleEffect(0.75).frame(width: 28) }
        }
        .padding(.horizontal, 16).frame(minHeight: 44)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(playing ? "Sonivo, музыка играет" : "Sonivo")
        .accessibilityIdentifier("sonivo.capture.brand")
    }
}
