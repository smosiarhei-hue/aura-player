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

// MARK: - Tabs

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
        case .home:    return "house.fill"
        case .new:     return "sparkles"
        case .radio:   return "dot.radiowaves.left.and.right"
        case .library: return "music.note.list"
        case .search:  return "magnifyingglass"
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var tab: AppTab = .home
    @State private var showPlayer = false
    @Namespace private var playerNamespace

    private var miniVisible: Bool { player.currentTrack != nil }

    /// Запас снизу под плавающий док и мини-плеер, чтобы контент никогда не уезжал под них.
    private var bottomReserve: CGFloat { miniVisible ? 156 : 90 }

    var body: some View {
        ZStack(alignment: .bottom) {
            AG.bg.ignoresSafeArea()

            TabView(selection: $tab) {
                HomeView()
                    .modifier(SonivoTabRoot(reserve: bottomReserve))
                    .tag(AppTab.home)
                NewReleasesView()
                    .modifier(SonivoTabRoot(reserve: bottomReserve))
                    .tag(AppTab.new)
                RadioStationsView()
                    .modifier(SonivoTabRoot(reserve: bottomReserve))
                    .tag(AppTab.radio)
                LibraryView()
                    .modifier(SonivoTabRoot(reserve: bottomReserve))
                    .tag(AppTab.library)
                SearchCatalogView()
                    .modifier(SonivoTabRoot(reserve: bottomReserve))
                    .tag(AppTab.search)
            }

            // Мини-плеер стоит НАД доком, а не поверх него.
            VStack(spacing: 10) {
                if miniVisible {
                    LiquidGlassMiniPlayer(showPlayer: $showPlayer, namespace: playerNamespace)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                SonivoTabBar(selection: $tab)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .opacity(showPlayer ? 0 : 1)
            .allowsHitTesting(!showPlayer)
        }
        .overlay {
            if showPlayer {
                PlayerScreen(isPresented: $showPlayer, namespace: playerNamespace)
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showPlayer)
        .animation(.spring(response: 0.35, dampingFraction: 0.80), value: miniVisible)
        .onAppear {
            PlayerCore.shared.installSpectrumTap()
        }
        .onChange(of: player.currentTrack?.id) { _ in
            rememberCurrentTrack()
        }
    }

    /// Запоминаем каждый запущенный трек — на этой истории «Моя волна» больше не повторяется.
    private func rememberCurrentTrack() {
        guard let track = player.currentTrack else { return }
        YandexMusicService.shared.remember(
            key: track.id.uuidString,
            artist: track.artist,
            ymTrackId: YandexMusicService.ymId(fromFileName: track.fileName)
        )
    }
}

/// Прячет родной таб-бар и резервирует место под наш собственный док.
struct SonivoTabRoot: ViewModifier {
    let reserve: CGFloat

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: reserve)
            }
            .toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Floating Ember Dock

struct SonivoTabBar: View {
    @Binding var selection: AppTab
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                Button {
                    if item != selection, settings.hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = item
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: selection == item ? .bold : .medium))
                            .frame(height: 20)
                        Text(item.label)
                            .font(AG.text(9.5, selection == item ? .bold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selection == item ? AnyShapeStyle(AG.emberGradient) : AnyShapeStyle(AG.inkMuted))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AG.hairline, lineWidth: 0.9)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Liquid Glass Mini Player

struct LiquidGlassMiniPlayer: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool
    let namespace: Namespace.ID

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.progress / player.duration))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                open()
            } label: {
                HStack(spacing: 12) {
                    SmallArtwork(track: player.currentTrack, size: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .matchedGeometryEffect(id: "heroArtwork", in: namespace)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "")
                            .font(AG.text(14, .semibold))
                            .foregroundStyle(AG.ink)
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .font(AG.text(11, .medium))
                            .foregroundStyle(AG.inkMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AG.emberGradient))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AG.ink.opacity(0.85))
                    .frame(width: 32, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.38))
            }
        )
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Capsule()
                    .fill(AG.emberGradient)
                    .frame(width: geo.size.width * fraction, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.40), location: 0.0),
                            .init(color: AG.amber.opacity(0.22), location: 0.35),
                            .init(color: .clear, location: 0.70),
                            .init(color: Color.black.opacity(0.30), location: 1.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.42), radius: 16, x: 0, y: 7)
        .gesture(
            DragGesture(minimumDistance: 15)
                .onEnded { value in
                    if value.translation.height < -20 { open() }
                }
        )
    }

    private func open() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            showPlayer = true
        }
    }
}
