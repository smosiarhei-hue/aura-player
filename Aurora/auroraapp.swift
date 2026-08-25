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

// MARK: - Root

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var showPlayer = false
    @State private var selectedTab: MainTab = .library

    enum MainTab: String, CaseIterable {
        case library, explore, settings
        var icon: String {
            switch self {
            case .library:  return "music.note.list"
            case .explore:  return "compass"
            case .settings: return "gearshape"
            }
        }
        var label: String {
            switch self {
            case .library:  return "Библиотека"
            case .explore:  return "Обзор"
            case .settings: return "Настройки"
            }
        }
    }

    var body: some View {
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
        .liquidGlassTabBar()
        // Mini player sits above tab bar
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil && !showPlayer {
                MiniPlayerBar(showPlayer: $showPlayer)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentTrack != nil)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen()
        }
        .onAppear { PlayerCore.shared.installSpectrumTap() }
    }
}

// MARK: - Liquid Glass Tab Bar modifier

extension View {
    @available(iOS 16.0, *)
    func liquidGlassTabBar() -> some View {
        self
            .toolbarBackground(.regularMaterial, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)
    }
}

// MARK: - Mini Player

struct MiniPlayerBar: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool

    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 10) {
                SmallArtwork(palette: player.currentTrack?.palette ?? Palette.seeded(1).colors, size: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                ZStack {
                    Circle().trim(from: 0, to: player.duration > 0 ? player.progress / player.duration : 0)
                        .stroke(SettingsStore.shared.accentGradient, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 28, height: 28)
                    Circle().stroke(.primary.opacity(0.08), lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.primary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}
