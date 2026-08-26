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

// MARK: - Root View (Sonivo 5 Tabs Dock & Floating Mini-Player)

enum AppTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case new = "New"
    case radio = "Radio"
    case library = "Library"
    case search = "Search"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home:    return "Home"
        case .new:     return "New"
        case .radio:   return "Radio"
        case .library: return "Library"
        case .search:  return "Search"
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
    @State private var selectedTab: AppTab = .home
    @State private var showPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Main Tab View with explicit ViewBuilder
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Stack: Floating Mini Player + Floating Liquid Glass Dock
            VStack(spacing: 8) {
                if player.currentTrack != nil && !showPlayer {
                    FloatingMiniPlayer(showPlayer: $showPlayer)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                FloatingLiquidGlassTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: player.currentTrack != nil)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen()
        }
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .home:
            HomeView()
        case .new:
            NewReleasesView()
        case .radio:
            RadioStationsView()
        case .library:
            LibraryView()
        case .search:
            SearchCatalogView()
        }
    }
}

// MARK: - Floating Mini Player with Tap and Swipe-Up Support

struct FloatingMiniPlayer: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Square Artwork
            SmallArtwork(track: player.currentTrack, size: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Track Title & Artist (Tappable / Swipeable)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(player.currentTrack?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                showPlayer = true
            }

            Spacer()

            // Play / Pause Button
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)

            // Next Track Button
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassOrMaterial(corner: 18)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if value.translation.height < -20 {
                        showPlayer = true
                    }
                }
        )
    }
}

// MARK: - Floating Liquid Glass Tab Bar

struct FloatingLiquidGlassTabBar: View {
    @Binding var selectedTab: AppTab
    @Namespace private var tabNamespace

    private var accent: Color { Color(hex: "#FF455B") ?? .pink }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = selectedTab == tab

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 20, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                            .frame(height: 24)

                        Text(tab.label)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.primary.opacity(0.10))
                                .matchedGeometryEffect(id: "activeTabPill", in: tabNamespace)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassCapsule()
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
    }
}
