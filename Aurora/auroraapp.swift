import SwiftUI

@main
struct AuroraApp: App {
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(settings.colorScheme)
                .tint(settings.accentColor)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var showPlayer = false
    @State private var selectedTab: MainTab = .library

    enum MainTab: String, CaseIterable {
        case library, explore, settings
        var icon: String {
            switch self {
            case .library:  return "music.note.house.fill"
            case .explore:  return "sparkles.rectangle.stack.fill"
            case .settings: return "gearshape.fill"
            }
        }
        var label: String {
            switch self {
            case .library:  return "Медиатека"
            case .explore:  return "Импорт"
            case .settings: return "Настройки"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LibraryView()
                    .tabItem { Label(MainTab.library.label, systemImage: MainTab.library.icon) }
                    .tag(MainTab.library)

                ExploreView()
                    .tabItem { Label(MainTab.explore.label, systemImage: MainTab.explore.icon) }
                    .tag(MainTab.explore)

                SettingsView()
                    .tabItem { Label(MainTab.settings.label, systemImage: MainTab.settings.icon) }
                    .tag(MainTab.settings)
            }

            // Floating Liquid Glass Mini Player (Apple Music style)
            if player.currentTrack != nil && !showPlayer {
                FloatingMiniPlayer(showPlayer: $showPlayer)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 54)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentTrack != nil)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen()
        }
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
        }
    }
}

// MARK: - Floating Liquid Glass Mini Player

struct FloatingMiniPlayer: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @Binding var showPlayer: Bool

    var body: some View {
        Button {
            showPlayer = true
        } label: {
            HStack(spacing: 12) {
                SmallArtwork(track: player.currentTrack, size: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text(player.currentTrack?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Play / Pause Action
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                // Next Track Action
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .liquidGlass(corner: 16, padding: 0, opacity: 0.95)
    }
}
