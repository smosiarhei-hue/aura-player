import SwiftUI
import UIKit

@main
struct SonivoApp: App {
    init() {
        let appearance = UITabBarAppearance(); appearance.configureWithTransparentBackground()
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.72)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.72)]
        appearance.stackedLayoutAppearance.selected.iconColor = .white
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.inlineLayoutAppearance = appearance.stackedLayoutAppearance
        appearance.compactInlineLayoutAppearance = appearance.stackedLayoutAppearance
        let tabBar = UITabBar.appearance(); tabBar.standardAppearance = appearance; tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .white; tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.72)
    }
    var body: some Scene { WindowGroup { RootView().preferredColorScheme(.dark).tint(.white) } }
}

enum AppTab: String, CaseIterable, Identifiable {
    case wave = "Wave", trends = "Trends", library = "Library", search = "Search"
    var id: String { rawValue }
    var label: String { switch self { case .wave: "Моя волна"; case .trends: "Тренды"; case .library: "Коллекция"; case .search: "Поиск" } }
    var icon: String { switch self { case .wave: "sparkles"; case .trends: "chart.line.uptrend.xyaxis"; case .library: "books.vertical.fill"; case .search: "magnifyingglass" } }
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
    private var v2OwnsPlayback: Bool { engineSelection.isV2Enabled && v2.currentTrack != nil }
    private var presentedTrack: Track? { v2OwnsPlayback ? v2.currentTrack : player.currentTrack }
    private var presentedIsPlaying: Bool { v2OwnsPlayback ? v2.isPlaying : player.isPlaying }
    private var miniVisible: Bool {
        guard let track = presentedTrack else { return false }
        return !track.title.isEmpty || track.isStream || track.duration > 0
    }
    var body: some View {
        TabView(selection: $tab) {
            Tab(AppTab.wave.label, systemImage: AppTab.wave.icon, value: .wave) { HomeView() }
            Tab(AppTab.trends.label, systemImage: AppTab.trends.icon, value: .trends) { TrendsExploreView() }
            Tab(AppTab.library.label, systemImage: AppTab.library.icon, value: .library) { LibraryView() }
            Tab(AppTab.search.label, systemImage: AppTab.search.icon, value: .search, role: .search) { SearchCatalogView() }
        }
        .tint(.white).toolbarColorScheme(.dark, for: .tabBar).tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if miniVisible { NativeMiniPlayer(showPlayer: $showPlayer, zoomNamespace: playerTransition) }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreenV2(isPresented: $showPlayer)
                .navigationTransition(.zoom(sourceID: Self.playerZoomID, in: playerTransition)).ignoresSafeArea()
        }
        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
            player.setApplicationSceneActive(scenePhase == .active)
            AutoMixV2NowPlayingCenter.shared.setFullPlayerVisible(showPlayer)
        }
        .onChange(of: showPlayer) { _, visible in
            AutoMixV2NowPlayingCenter.shared.setFullPlayerVisible(visible)
        }
        .onChange(of: scenePhase) { _, phase in
            player.setApplicationSceneActive(phase == .active)
            AutoMixV2NowPlayingCenter.shared.setFullPlayerVisible(showPlayer)
            if phase == .active, presentedIsPlaying { PlaybackAudioSessionCoordinator.shared.activateForPlayback() }
        }
        .onOpenURL { _ in showPlayer = true }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { _ in showPlayer = true }
        .onContinueUserActivity("com.apple.mediaitem") { _ in showPlayer = true }
        .onChange(of: player.currentTrack?.id) { _, _ in rememberCurrentTrack() }
        .onChange(of: v2.currentTrack?.id) { _, _ in rememberCurrentTrack() }
        .onChange(of: player.isPlaying) { _, playing in
            if !v2OwnsPlayback, playing { PlaybackAudioSessionCoordinator.shared.activateForPlayback() }
        }
        .onChange(of: v2.isPlaying) { _, playing in
            if v2OwnsPlayback, playing { PlaybackAudioSessionCoordinator.shared.activateForPlayback() }
        }
    }
    private func rememberCurrentTrack() {
        guard let track = presentedTrack else { return }
        YandexMusicService.shared.remember(key: track.id.uuidString, artist: track.artist,
                                           ymTrackId: YandexMusicService.ymId(fromFileName: track.fileName))
    }
}

struct NativeMiniPlayer: View {
    @State private var player = ActivePlayerPresentation()
    @Binding var showPlayer: Bool
    let zoomNamespace: Namespace.ID
    @ScaledMetric(relativeTo: .body) private var controlSide: CGFloat = 44
    private var tapSide: CGFloat { max(44, min(controlSide, 56)) }
    private var track: Track? { player.currentTrack }
    private var isPlaying: Bool { player.isPlaying }
    private var isLoading: Bool { player.isLoading }
    private var playbackFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }
    private var statusText: String {
        if let value = player.downloadProgress, player.isDownloading { return "Загрузка трека \(Int(value * 100))%" }
        if let value = player.nextDownloadProgress, player.isNextDownloading { return "Следующий трек \(Int(value * 100))%" }
        if isLoading { return "Подготовка полного трека…" }
        return track?.artist ?? ""
    }
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        MiniArtworkPulse(track: track, isPlaying: isPlaying).frame(width: 44, height: 44).clipped()
                            .matchedTransitionSource(id: RootView.playerZoomID, in: zoomNamespace)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track?.title ?? "").font(AG.rounded(.headline, .semibold)).foregroundStyle(AG.ink)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Text(statusText).font(AG.rounded(.subheadline))
                                .foregroundStyle((isLoading || player.isDownloading || player.isNextDownloading) ? AG.amber : AG.inkMuted)
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(action: togglePlayback) {
                    Group {
                        if isLoading { ProgressView().tint(AG.ink) }
                        else { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(AG.glyph(.bold)).foregroundStyle(AG.ink)
                                .contentTransition(.symbolEffect(.replace)) }
                    }.frame(width: tapSide, height: tapSide).contentShape(Circle())
                }.buttonStyle(.plain).disabled(isLoading)
                    .accessibilityLabel(isLoading ? "Загрузка трека" : (isPlaying ? "Пауза" : "Воспроизвести"))
                Button(action: nextTrack) {
                    Image(systemName: "forward.fill").font(AG.glyph(.bold)).foregroundStyle(AG.ink)
                        .frame(width: tapSide, height: tapSide).contentShape(Circle())
                }.buttonStyle(.plain).disabled(isLoading).accessibilityLabel("Следующий трек")
            }
            ZStack(alignment: .leading) {
                if let buffered = player.downloadProgress ?? player.nextDownloadProgress,
                   player.isDownloading || player.isNextDownloading {
                    ProgressView(value: buffered).progressViewStyle(.linear).tint(AG.amber.opacity(0.55))
                }
                ProgressView(value: playbackFraction).progressViewStyle(.linear).tint(AG.ink)
            }.scaleEffect(x: 1, y: 0.55)
        }
        .frame(maxWidth: .infinity).padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 3)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1).contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < -20 { open() } })
        .task { await player.observeTimeline() }
    }
    private func open() { Haptics.tap(.light); showPlayer = true }
    private func togglePlayback() { Haptics.tap(.medium); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.togglePlay() }
    private func nextTrack() { Haptics.tap(.light); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.next() }
}

struct MiniArtworkPulse: View {
    let track: Track?
    let isPlaying: Bool
    @ScaledMetric(relativeTo: .body) private var artworkSide: CGFloat = 40
    private var side: CGFloat { min(40, max(36, artworkSide)) }
    var body: some View {
        SmallArtwork(track: track, size: side).frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(isPlaying ? 0.35 : 0.15), lineWidth: 0.8) }
            .frame(width: 44, height: 44).clipped().compositingGroup()
    }
}
