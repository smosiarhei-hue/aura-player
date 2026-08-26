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

// MARK: - Root View (Sonivo 5 Tabs Dock & Seamless Liquid Glass Player Expansion)

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
        case .new:     return "Новости"
        case .radio:   return "Радио"
        case .library: return "Библиотека"
        case .search:  return "Поиск"
        }
    }

    var icon: String {
        switch self {
        case .home:    return "house.fill"
        case .new:     return "square.grid.2x2.fill"
        case .radio:   return "dot.radiowaves.left.and.right"
        case .library: return "music.note.list"
        case .search:  return "magnifyingglass"
        }
    }
}

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var showPlayer = false
    @Namespace private var playerNamespace

    var body: some View {
        ZStack {
            // Main App Tabs
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Floating Mini Player (Liquid Glass) hovering right above the tab bar
                    if player.currentTrack != nil && !showPlayer {
                        LiquidGlassMiniPlayer(showPlayer: $showPlayer, namespace: playerNamespace)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }
                }

            // Full Player Screen with ultra-smooth 120Hz slide-up & drag-down transition
            if showPlayer {
                PlayerScreen(isPresented: $showPlayer, namespace: playerNamespace)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showPlayer)
        .animation(.spring(response: 0.35, dampingFraction: 0.80), value: player.currentTrack != nil)
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
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
    }
}

// MARK: - Liquid Glass Mini Player (Screenshot 2 Match)

struct LiquidGlassMiniPlayer: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            // Tappable artwork + metadata
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showPlayer = true
                }
            } label: {
                HStack(spacing: 12) {
                    SmallArtwork(track: player.currentTrack, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .matchedGeometryEffect(id: "heroArtwork", in: namespace)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Play / Pause Button
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Next Track Button
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.40), location: 0.0),
                                    .init(color: .white.opacity(0.10), location: 0.40),
                                    .init(color: .clear, location: 0.70),
                                    .init(color: Color.black.opacity(0.30), location: 1.0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if value.translation.height < -20 {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            showPlayer = true
                        }
                    }
                }
        )
    }
}
