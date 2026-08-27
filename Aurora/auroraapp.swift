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

// MARK: - Native tabs

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case new = "New"
    case radio = "Radio"
    case library = "Library"
    case search = "Search"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:    return "Главная"
        case .new:     return "Новое"
        case .radio:   return "Радио"
        case .library: return "Библиотека"
        case .search:  return "Поиск"
        }
    }

    var icon: String {
        switch self {
        case .home:    return "house"
        case .new:     return "sparkles"
        case .radio:   return "dot.radiowaves.left.and.right"
        case .library: return "music.note.list"
        case .search:  return "magnifyingglass"
        }
    }
}

// MARK: - Root

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @Namespace private var playerNamespace

    private var miniVisible: Bool { player.currentTrack != nil }

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label(AppTab.home.label, systemImage: AppTab.home.icon) }
                .tag(AppTab.home)

            NewReleasesView()
                .tabItem { Label(AppTab.new.label, systemImage: AppTab.new.icon) }
                .tag(AppTab.new)

            RadioStationsView()
                .tabItem { Label(AppTab.radio.label, systemImage: AppTab.radio.icon) }
                .tag(AppTab.radio)

            LibraryView()
                .tabItem { Label(AppTab.library.label, systemImage: AppTab.library.icon) }
                .tag(AppTab.library)

            SearchCatalogView()
                .tabItem { Label(AppTab.search.label, systemImage: AppTab.search.icon) }
                .tag(AppTab.search)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if miniVisible {
                NativeMiniPlayer(showPlayer: $showPlayer, namespace: playerNamespace)
            }
        }
        .overlay {
            if showPlayer {
                PlayerScreen(isPresented: $showPlayer, namespace: playerNamespace)
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .bottom)))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: showPlayer)
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
        }
        .onChange(of: player.currentTrack?.id) { _ in
            rememberCurrentTrack()
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

// MARK: - Native TabView bottom accessory

struct NativeMiniPlayer: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool
    let namespace: Namespace.ID

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 11) {
                Button(action: open) {
                    HStack(spacing: 11) {
                        MiniArtworkPulse(
                            track: player.currentTrack,
                            isPlaying: player.isPlaying,
                            namespace: namespace
                        )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.currentTrack?.title ?? "Не выбрана песня")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Text(player.currentTrack?.artist ?? "")
                                .font(.system(.subheadline, design: .rounded, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Следующая песня")
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(AG.amber)
                .scaleEffect(x: 1, y: 0.55, anchor: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    if value.translation.height < -24 { open() }
                }
        )
    }

    private func open() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            showPlayer = true
        }
    }
}

// MARK: - Animated artwork in mini-player

struct MiniArtworkPulse: View {
    let track: Track?
    let isPlaying: Bool
    let namespace: Namespace.ID

    @State private var rotate = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    AngularGradient(
                        colors: [AG.amber, AG.ember, Color.clear, AG.amber],
                        center: .center
                    )
                )
                .frame(width: 48, height: 48)
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .blur(radius: 5)
                .opacity(isPlaying ? 0.72 : 0.18)

            SmallArtwork(track: track, size: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .matchedGeometryEffect(id: "heroArtwork", in: namespace)
                .scaleEffect(isPlaying ? 1.0 : 0.94)
        }
        .frame(width: 48, height: 48)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isPlaying)
        .onAppear {
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                rotate = true
            }
        }
    }
}
