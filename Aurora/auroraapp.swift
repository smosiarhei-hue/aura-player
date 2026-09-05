import SwiftUI
import UIKit

@main
struct SonivoApp: App {
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
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case wave = "Wave"
    case trends = "Trends"
    case library = "Library"
    case search = "Search"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wave: return "Моя волна"
        case .trends: return "Тренды"
        case .library: return "Коллекция"
        case .search: return "Поиск"
        }
    }

    var icon: String {
        switch self {
        case .wave: return "sparkles"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .library: return "books.vertical.fill"
        case .search: return "magnifyingglass"
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = PlayerCore.shared
    @State private var v2 = AutoMixV2Runtime.shared
    @State private var engineSelection = AutoMixEngineSelectionStore.shared
    @State private var tab: AppTab = .wave
    @State private var showPlayer = false
    @Namespace private var playerTransition

    static let playerZoomID = "now-playing-artwork"

    private var presentedTrack: Track? {
        engineSelection.isV2Enabled ? v2.currentTrack : player.currentTrack
    }

    private var presentedIsPlaying: Bool {
        engineSelection.isV2Enabled ? v2.isPlaying : player.isPlaying
    }

    private var miniVisible: Bool {
        guard let track = presentedTrack else { return false }
        return !track.title.isEmpty || track.isStream || track.duration > 0
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(AppTab.wave.label, systemImage: AppTab.wave.icon, value: .wave) {
                HomeView()
            }
            Tab(AppTab.trends.label, systemImage: AppTab.trends.icon, value: .trends) {
                TrendsExploreView()
            }
            Tab(AppTab.library.label, systemImage: AppTab.library.icon, value: .library) {
                LibraryView()
            }
            Tab(AppTab.search.label, systemImage: AppTab.search.icon, value: .search, role: .search) {
                SearchCatalogView()
            }
        }
        .tint(.white)
        .toolbarColorScheme(.dark, for: .tabBar)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if miniVisible {
                NativeMiniPlayer(showPlayer: $showPlayer, zoomNamespace: playerTransition)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreenV2(isPresented: $showPlayer)
                .navigationTransition(.zoom(sourceID: Self.playerZoomID, in: playerTransition))
                .ignoresSafeArea()
        }
        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
            player.setApplicationSceneActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { oldPhase, phase in
            player.setApplicationSceneActive(phase == .active)
            if phase == .active, oldPhase != .active, presentedIsPlaying {
                showPlayer = true
            }
        }
        .onOpenURL { _ in showPlayer = true }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { _ in showPlayer = true }
        .onContinueUserActivity("com.apple.mediaitem") { _ in showPlayer = true }
        .onChange(of: player.currentTrack?.id) { _, _ in rememberCurrentTrack() }
        .onChange(of: v2.currentTrack?.id) { _, _ in rememberCurrentTrack() }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if !engineSelection.isV2Enabled, isPlaying {
                PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            }
        }
        .onChange(of: v2.isPlaying) { _, isPlaying in
            if engineSelection.isV2Enabled, isPlaying {
                PlaybackAudioSessionCoordinator.shared.activateForPlayback()
            }
        }
    }

    private func rememberCurrentTrack() {
        guard let track = presentedTrack else { return }
        YandexMusicService.shared.remember(
            key: track.id.uuidString,
            artist: track.artist,
            ymTrackId: YandexMusicService.ymId(fromFileName: track.fileName)
        )
    }
}

struct NativeMiniPlayer: View {
    @State private var player = PlayerCore.shared
    @State private var v2 = AutoMixV2Runtime.shared
    @State private var engineSelection = AutoMixEngineSelectionStore.shared
    @Binding var showPlayer: Bool
    let zoomNamespace: Namespace.ID
    @ScaledMetric(relativeTo: .body) private var controlSide: CGFloat = 44

    private var tapSide: CGFloat { max(44, min(controlSide, 56)) }
    private var track: Track? { engineSelection.isV2Enabled ? v2.currentTrack : player.currentTrack }
    private var isPlaying: Bool { engineSelection.isV2Enabled ? v2.isPlaying : player.isPlaying }
    private var isLoading: Bool { engineSelection.isV2Enabled && v2.isLoading }

    private var progress: Double {
        guard !engineSelection.isV2Enabled, player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        MiniArtworkPulse(track: track, isPlaying: isPlaying)
                            .frame(width: 44, height: 44)
                            .clipped()
                            .matchedTransitionSource(id: RootView.playerZoomID, in: zoomNamespace)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track?.title ?? "")
                                .font(AG.rounded(.headline, .semibold))
                                .foregroundStyle(AG.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text(isLoading ? "Загрузка полного трека…" : (track?.artist ?? ""))
                                .font(AG.rounded(.subheadline))
                                .foregroundStyle(isLoading ? AG.amber : AG.inkMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: togglePlayback) {
                    Group {
                        if isLoading {
                            ProgressView().tint(AG.ink)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(AG.glyph(.bold))
                                .foregroundStyle(AG.ink)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: tapSide, height: tapSide)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel(isLoading ? "Загрузка трека" : (isPlaying ? "Пауза" : "Воспроизвести"))

                Button(action: nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(AG.glyph(.bold))
                        .foregroundStyle(AG.ink)
                        .frame(width: tapSide, height: tapSide)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel("Следующий трек")
            }

            if isLoading {
                ProgressView().progressViewStyle(.linear).tint(AG.amber)
            } else {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AG.ink)
                    .scaleEffect(x: 1, y: 0.45)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    if value.translation.height < -20 { open() }
                }
        )
    }

    private func open() {
        Haptics.tap(.light)
        showPlayer = true
    }

    private func togglePlayback() {
        Haptics.tap(.medium)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        PlaybackCommandRouter.shared.toggle()
    }

    private func nextTrack() {
        Haptics.tap(.light)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        PlaybackCommandRouter.shared.next()
    }
}

struct MiniArtworkPulse: View {
    let track: Track?
    let isPlaying: Bool

    @ScaledMetric(relativeTo: .body) private var artworkSide: CGFloat = 40

    private var side: CGFloat { min(40, max(36, artworkSide)) }

    var body: some View {
        SmallArtwork(track: track, size: side)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(isPlaying ? 0.35 : 0.15), lineWidth: 0.8)
            }
            .frame(width: 44, height: 44)
            .clipped()
            .compositingGroup()
    }
}
