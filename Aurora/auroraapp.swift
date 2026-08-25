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
    @State private var selectedTab: MainTab = .library
    @State private var showPlayer = false
    @State private var previousTab: MainTab = .library

    enum MainTab: String {
        case library, explore, equalizer, settings
        var icon: String {
            switch self {
            case .library:   return "music.note.list"
            case .explore:   return "compass"
            case .equalizer: return "slider.horizontal.3"
            case .settings:  return "gearshape"
            }
        }
    }

    var body: some View {
        ZStack {
            // Tab content
            Group {
                switch selectedTab {
                case .library:   LibraryView()
                case .explore:   ExploreView()
                case .equalizer: EqualizerView()
                case .settings:  SettingsView()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)

            // Mini player overlay
            VStack {
                Spacer()
                if player.currentTrack != nil {
                    MiniPlayerBar(showPlayer: $showPlayer)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentTrack != nil)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen()
        }
        // Floating glass tab bar (iOS 27 style)
        .overlay(alignment: .bottom) {
            if !(showPlayer) {
                LiquidTabBar(selected: $selectedTab)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { PlayerCore.shared.installSpectrumTap() }
    }
}

// MARK: - Liquid Glass Tab Bar (iOS 27)

struct LiquidTabBar: View {
    @Binding var selected: RootView.MainTab
    @State private var previousTab: RootView.MainTab?

    var body: some View {
        HStack(spacing: 0) {
            ForEach([RootView.MainTab.library, .explore, .equalizer, .settings], id: \.rawValue) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .liquidGlass(corner: 32, padding: 0)
    }

    private func tabButton(_ tab: RootView.MainTab) -> some View {
        let isActive = selected == tab
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selected = tab
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    // Active indicator pill
                    if isActive {
                        Capsule()
                            .fill(SettingsStore.shared.accentGradient)
                            .frame(width: 56, height: 32)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Image(systemName: tab.icon)
                        .font(.system(size: 18, weight: isActive ? .semibold : .regular))
                        .frame(width: 56, height: 32)
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Mini Player (Liquid Glass)

struct MiniPlayerBar: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool

    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 12) {
                SmallArtwork(palette: player.currentTrack?.palette ?? Palette.seeded(1).colors, size: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1).foregroundStyle(.primary)
                    Text(player.currentTrack?.artist ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                // Progress ring
                ZStack {
                    Circle().trim(from: 0, to: player.duration > 0 ? player.progress / player.duration : 0)
                        .stroke(SettingsStore.shared.accentGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 32, height: 32)
                    Circle().stroke(.primary.opacity(0.1), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
        }
        .buttonStyle(.plain)
        .liquidGlass(corner: 22, padding: 0)
    }
}