import SwiftUI

@main
struct AuroraApp: App {
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(settings.colorScheme)
                .tint(settings.accentColor)
        }
    }
}

// MARK: - Root

struct RootView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var selection = 0
    @State private var showPlayer = false

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .tabItem { Label("Медиатека", systemImage: "music.note.list") }
                .tag(0)
            ImportView()
                .tabItem { Label("Импорт", systemImage: "square.and.arrow.down.on.square") }
                .tag(1)
            EqualizerView()
                .tabItem { Label("Эквалайзер", systemImage: "slider.horizontal.3") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(3)
        }
        .overlay(alignment: .bottom) {
            if player.currentTrack != nil {
                MiniPlayerBar(showPlayer: $showPlayer)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: player.currentTrack != nil)
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen()
        }
        .onAppear { PlayerCore.shared.installSpectrumTap() }
    }
}

// MARK: - Mini Player

struct MiniPlayerBar: View {
    @StateObject private var player = PlayerCore.shared
    @Binding var showPlayer: Bool

    var body: some View {
        Button { showPlayer = true } label: {
            HStack(spacing: 10) {
                SmallArtwork(palette: player.currentTrack?.palette ?? Palette.seeded(1).colors, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(player.formatted(player.progress) + " / " + player.formatted(player.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassCard(corner: 18)
        }
        .buttonStyle(.plain)
    }
}
