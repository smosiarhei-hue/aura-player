import SwiftUI
import UIKit

@main
struct SonivoApp: App {
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(settings.colorScheme)
                .tint(AG.amber)
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
    @StateObject private var player = PlayerCore.shared
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
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if miniVisible {
                NativeMiniPlayer(showPlayer: $showPlayer)
            }
        }
        .overlay {
            if showPlayer {
                PlayerScreenV2(isPresented: $showPlayer)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.40, dampingFraction: 0.90), value: showPlayer)
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
            PlaybackAudioSessionCoordinator.shared.install()
        }
        .onChange(of: player.currentTrack?.id) { _ in rememberCurrentTrack() }
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
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        MiniArtworkPulse(track: player.currentTrack, isPlaying: player.isPlaying)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.currentTrack?.title ?? "Не выбрана песня")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(player.currentTrack?.artist ?? "")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(AG.amber)
                .scaleEffect(x: 1, y: 0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 18).onEnded { value in
            if value.translation.height < -24 { open() }
        })
    }

    private func open() {
        guard !showPlayer else { return }
        withAnimation(.spring(response: 0.40, dampingFraction: 0.90)) { showPlayer = true }
    }
}

struct MiniArtworkPulse: View {
    let track: Track?
    let isPlaying: Bool
    @State private var rotate = false

    var body: some View {
        ZStack {
            SmallArtwork(track: track, size: 42)
                .frame(width: 42, height: 42)
                .clipped()

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    AngularGradient(colors: [AG.amber, AG.ember, .clear, AG.amber], center: .center),
                    lineWidth: isPlaying ? 2.2 : 0.8
                )
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .opacity(isPlaying ? 0.9 : 0.35)
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .compositingGroup()
        .scaleEffect(isPlaying ? 1 : 0.96)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPlaying)
        .onAppear {
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { rotate = true }
        }
    }
}
