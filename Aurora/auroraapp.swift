import SwiftUI
import UIKit

@main
struct SonivoApp: App {
    @State private var settings = SettingsStore.shared

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.72)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.72)]
        appearance.stackedLayoutAppearance.selected.iconColor = .white
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.inlineLayoutAppearance = appearance.stackedLayoutAppearance
        appearance.compactInlineLayoutAppearance = appearance.stackedLayoutAppearance

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .white
        tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.72)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(settings.colorScheme)
                .tint(.white)
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case new = "New"
    case radio = "Radio"
    case library = "Library"
    case search = "Search"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Главная"
        case .new: return "Новое"
        case .radio: return "Радио"
        case .library: return "Библиотека"
        case .search: return "Поиск"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .new: return "sparkles"
        case .radio: return "dot.radiowaves.left.and.right"
        case .library: return "music.note.list"
        case .search: return "magnifyingglass"
        }
    }
}

struct RootView: View {
    @State private var player = PlayerCore.shared
    @State private var tab: AppTab = .home
    @State private var showPlayer = false

    private var miniVisible: Bool { player.currentTrack != nil }

    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label(AppTab.home.label, systemImage: AppTab.home.icon) }.tag(AppTab.home)
            NewReleasesView().tabItem { Label(AppTab.new.label, systemImage: AppTab.new.icon) }.tag(AppTab.new)
            RadioStationsView().tabItem { Label(AppTab.radio.label, systemImage: AppTab.radio.icon) }.tag(AppTab.radio)
            LibraryView().tabItem { Label(AppTab.library.label, systemImage: AppTab.library.icon) }.tag(AppTab.library)
            SearchCatalogView().tabItem { Label(AppTab.search.label, systemImage: AppTab.search.icon) }.tag(AppTab.search)
        }
        .tint(.white)
        .toolbarColorScheme(.dark, for: .tabBar)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if miniVisible {
                NativeMiniPlayer(showPlayer: $showPlayer)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreenV2(isPresented: $showPlayer)
                .presentationBackground(.clear)
        }
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
            PlaybackAudioSessionCoordinator.shared.install()
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            rememberCurrentTrack()
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying {
                PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            }
        }
    }

    private func rememberCurrentTrack() {
        guard let track = player.currentTrack else { return }
        YandexMusicService.shared.remember(
            key: track.id.uuidString,
            artist: track.artist,
            ymTrackId: YandexMusicService.ymId(fromFileName: track.fileName)
        )
    }
}

struct NativeMiniPlayer: View {
    @State private var player = PlayerCore.shared
    @Binding var showPlayer: Bool
    @State private var opening = false

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        MiniArtworkPulse(track: player.currentTrack, isPlaying: player.isPlaying)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.currentTrack?.title ?? "Не выбрана песня")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(player.currentTrack?.artist ?? "")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(opening || showPlayer)

                Button(action: togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")

                Button(action: nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Следующий трек")
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .scaleEffect(x: 1, y: 0.45)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
    }

    private func open() {
        guard !showPlayer, !opening else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        opening = true
        showPlayer = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            opening = false
        }
    }

    private func togglePlayback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.togglePlay()
    }

    private func nextTrack() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.next()
    }
}

struct MiniArtworkPulse: View {
    let track: Track?
    let isPlaying: Bool

    var body: some View {
        SmallArtwork(track: track, size: 40)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(isPlaying ? 0.38 : 0.18), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .compositingGroup()
    }
}
