import SwiftUI
import UIKit

@main
struct SonivoApp: App {
    init() {
        let appearance = UITabBarAppearance(); appearance.configureWithTransparentBackground()
        appearance.stackedLayoutAppearance.normal.iconColor = .secondaryLabel
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.secondaryLabel]
        appearance.stackedLayoutAppearance.selected.iconColor = .label
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.inlineLayoutAppearance = appearance.stackedLayoutAppearance
        appearance.compactInlineLayoutAppearance = appearance.stackedLayoutAppearance
        let tabBar = UITabBar.appearance(); tabBar.standardAppearance = appearance; tabBar.scrollEdgeAppearance = appearance
        tabBar.tintColor = .label; tabBar.unselectedItemTintColor = .secondaryLabel
        
        // Smooth ProMotion deceleration (120/220Hz feel) — long buttery kinetic coasting
        UIScrollView.appearance().decelerationRate = UIScrollView.DecelerationRate.normal
        UIScrollView.appearance().bounces = true
    }
    var body: some Scene { WindowGroup { SonivoLaunchHost() } }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home", browse = "Browse", radio = "Radio", library = "Library", search = "Search"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: "Главная"
        case .browse: "Новое"
        case .radio: "Радио"
        case .library: "Медиатека"
        case .search: "Поиск"
        }
    }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .browse: "square.grid.2x2.fill"
        case .radio: "dot.radiowaves.left.and.right"
        case .library: "square.stack.fill"
        case .search: "magnifyingglass"
        }
    }
}

struct RootView: View {
    var onExternalPlaybackOpen: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = PlayerCore.shared
    @State private var router = PlaybackCommandRouter.shared
    @State private var themeManager = ThemeFontManager.shared
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @Namespace private var playerTransition
    static let playerZoomID = "now-playing-artwork"
    private var v2OwnsPlayback: Bool { false }
    private var neuroOwnsPlayback: Bool { false }
    private var presentedTrack: Track? {
        player.currentTrack
    }
    private var presentedIsPlaying: Bool {
        player.isPlaying
    }
    private var miniVisible: Bool {
        guard let track = presentedTrack else { return false }
        return !track.title.isEmpty || track.isStream || track.duration > 0
    }
    var body: some View {
        TabView(selection: $tab) {
            Tab(AppTab.home.label, systemImage: AppTab.home.icon, value: .home) { SonivoHomeRedesignedView() }
            Tab(AppTab.browse.label, systemImage: AppTab.browse.icon, value: .browse) { TrendsExploreView() }
            Tab(AppTab.radio.label, systemImage: AppTab.radio.icon, value: .radio) { RadioStationsExploreView() }
            Tab(AppTab.library.label, systemImage: AppTab.library.icon, value: .library) { LibraryView() }
            Tab(AppTab.search.label, systemImage: AppTab.search.icon, value: .search, role: .search) { SearchCatalogView() }
        }
        .accessibilityIdentifier("sonivo.root.tabs")
        .tint(themeManager.accentColor).tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if miniVisible { NativeMiniPlayer(showPlayer: $showPlayer, zoomNamespace: playerTransition) }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreenV2(isPresented: $showPlayer)
                .navigationTransition(.zoom(sourceID: Self.playerZoomID, in: playerTransition)).ignoresSafeArea()
        }
        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
            let active = (scenePhase == .active)
            player.setApplicationSceneActive(active)
            AutoMixV2NowPlayingCenter.shared.setApplicationSceneActive(active)
            AutoMixV2NowPlayingCenter.shared.setFullPlayerVisible(showPlayer)
        }
        .onChange(of: showPlayer) { _, visible in
            AutoMixV2NowPlayingCenter.shared.setFullPlayerVisible(visible)
        }
        .onChange(of: scenePhase) { _, phase in
            let active = (phase == .active)
            player.setApplicationSceneActive(active)
            AutoMixV2NowPlayingCenter.shared.setApplicationSceneActive(active)
            AutoMixV2NowPlayingCenter.shared.setFullPlayerVisible(showPlayer)
            if active, presentedIsPlaying { PlaybackAudioSessionCoordinator.shared.activateForPlayback() }
        }
        .onOpenURL { _ in onExternalPlaybackOpen?(); showPlayer = true }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { _ in onExternalPlaybackOpen?(); showPlayer = true }
        .onContinueUserActivity("com.apple.mediaitem") { _ in onExternalPlaybackOpen?(); showPlayer = true }
        .onChange(of: player.currentTrack?.id) { _, _ in rememberCurrentTrack() }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { PlaybackAudioSessionCoordinator.shared.activateForPlayback() }
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
    private var track: Track? { player.displayTrack }
    private var isPlaying: Bool { player.isPlaying }
    @State private var showsWaitingStatus = false
    private var isWaitingForAudio: Bool { player.isLoading || player.isBuffering }
    private var playbackFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }
    private var statusText: String {
        if showsWaitingStatus && isWaitingForAudio {
            return player.isBuffering ? "Буферизация…" : "Подключение…"
        }
        return track?.artist ?? ""
    }
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        MiniPlayerArtwork(track: track)
                            .matchedTransitionSource(id: RootView.playerZoomID, in: zoomNamespace)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track?.title ?? "").font(SN.rounded(.headline, .semibold)).foregroundStyle(SN.ink)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            Text(statusText).font(SN.rounded(.subheadline))
                                .foregroundStyle((showsWaitingStatus && isWaitingForAudio) ? SN.amber : SN.inkMuted)
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))
                .accessibilityLabel(track.map { "Открыть плеер: \($0.title)" } ?? "Открыть плеер")
                Button(action: togglePlayback) {
                    Group {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(SN.glyph(.bold)).foregroundStyle(SN.ink)
                            .contentTransition(.symbolEffect(.replace))
                    }.frame(width: tapSide, height: tapSide).contentShape(Circle())
                }.buttonStyle(TactileButtonStyle(scale: 0.92))
                    .accessibilityLabel(isPlaying ? "Пауза" : "Воспроизвести")
                Button(action: nextTrack) {
                    Image(systemName: "forward.fill").font(SN.glyph(.bold)).foregroundStyle(SN.ink)
                        .frame(width: tapSide, height: tapSide).contentShape(Circle())
                }.buttonStyle(TactileButtonStyle(scale: 0.92)).accessibilityLabel("Следующий трек")
            }
            ProgressView(value: playbackFraction).progressViewStyle(.linear).tint(SN.ink)
                .scaleEffect(x: 1, y: 0.55)
        }
        .task(id: isWaitingForAudio) {
            showsWaitingStatus = false
            guard isWaitingForAudio else { return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled, isWaitingForAudio else { return }
            showsWaitingStatus = true
        }
        .frame(maxWidth: .infinity).padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1).contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < -20 { open() } })
        .task { await player.observeTimeline() }
    }
    private func open() { Haptics.tap(.light); showPlayer = true }
    private func togglePlayback() { Haptics.tap(.medium); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.togglePlay() }
    private func nextTrack() { Haptics.tap(.light); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.next() }
}

/// A stable, full-cover thumbnail. It never pulses, shrinks, or crops the source image.
struct MiniPlayerArtwork: View {
    let track: Track?
    private let side: CGFloat = 44

    var body: some View {
        Group {
            if let track, let image = LibraryStore.cachedArtworkImage(for: track) {
                fittedArtwork(Image(uiImage: image))
            } else if let cover = track?.coverURL, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        fittedArtwork(image)
                    } else {
                        placeholder
                    }
                }
                .id(track?.id)
            } else {
                placeholder
            }
        }
        .frame(width: side, height: side)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func fittedArtwork(_ image: Image) -> some View {
        image.resizable()
            .scaledToFit()
            .frame(width: side, height: side)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: track?.palette ?? [SN.accent, SN.flame],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Системный жест встряхивания устройства (Shake to Wave)

extension NSNotification.Name {
    static let deviceDidShakeNotification = NSNotification.Name("sonivo.deviceDidShakeNotification")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShakeNotification, object: event)
        }
    }
}
