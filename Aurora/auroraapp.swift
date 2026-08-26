import SwiftUI

@main
struct SonivoApp: App {
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(settings.colorScheme)
                .tint(settings.accentColor)
        }
    }
}

// MARK: - Root View (Native iOS 27 TabView + System Mini-Player Layer)

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var showPlayer = false
    @Namespace private var playerNamespace

    var body: some View {
        ZStack {
            // Native system TabView — Liquid Glass material, standard geometry,
            // Safe Area handling and native hit-testing all provided by the system.
            TabView {
                HomeView()
                    .tabItem { Label("Главная", systemImage: "house.fill") }
                NewReleasesView()
                    .tabItem { Label("Новости", systemImage: "square.grid.2x2.fill") }
                RadioStationsView()
                    .tabItem { Label("Радио", systemImage: "dot.radiowaves.left.and.right") }
                LibraryView()
                    .tabItem { Label("Библиотека", systemImage: "music.note.list") }
                SearchCatalogView()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
            }
            // Mini player as a dedicated system layer directly above the tab bar.
            // The system auto-insets every tab's content by this layer's height.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.currentTrack != nil && !showPlayer {
                    MiniPlayer(showPlayer: $showPlayer, namespace: playerNamespace)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Full player overlay with matched-geometry hero transition
            if showPlayer {
                PlayerScreen(isPresented: $showPlayer, namespace: playerNamespace)
                    .transition(.identity)
                    .zIndex(5)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: player.currentTrack != nil)
        .animation(.spring(response: 0.62, dampingFraction: 0.70), value: showPlayer)
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
        }
    }
}

// MARK: - Mini Player (system material bar directly above the tab bar)

struct MiniPlayer: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 8) {
            // Left: artwork + title (tap to open the full player)
            Button {
                showPlayer = true
            } label: {
                HStack(spacing: 12) {
                    SmallArtwork(track: player.currentTrack, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .matchedGeometryEffect(id: "heroArtwork", in: namespace)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Play / Pause
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Next track
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}
