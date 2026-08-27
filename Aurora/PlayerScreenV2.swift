import SwiftUI
import UIKit

struct PlayerScreenV2: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var analyzer = SpectrumAnalyzer.shared
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragY: CGFloat = 0
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var showArtistChoice = false
    @State private var resolvingArtist = false
    @State private var dismissing = false

    private var track: Track? { player.currentTrack }
    private var palette: [Color] { track?.palette ?? Palette.seeded(42).colors }
    private var beat: CGFloat {
        let source = max(analyzer.streamLevel, analyzer.bass, analyzer.level)
        return player.isPlaying ? CGFloat(min(max(source, 0), 1)) : 0
    }

    var body: some View {
        GeometryReader { geo in
            let coverSide = min(geo.size.width - 44, geo.size.height * 0.42)

            ZStack {
                background

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 12)
                    animatedCover(side: coverSide)
                    Spacer(minLength: 18)
                    metadata
                    scrubber.padding(.top, 18)
                    controls.padding(.top, 10)
                    bottomTools.padding(.top, 14)
                    Spacer(minLength: 10)
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, max(10, geo.safeAreaInsets.bottom))
            }
            .offset(y: max(0, dragY))
            .scaleEffect(1 - min(max(dragY, 0) / 1800, 0.035), anchor: .bottom)
            .opacity(1 - min(max(dragY, 0) / 650, 0.22))
        }
        .ignoresSafeArea(edges: .bottom)
        .statusBarHidden()
        .colorScheme(.dark)
        .interactiveDismissDisabled(dismissing)
        .confirmationDialog("Выберите исполнителя", isPresented: $showArtistChoice, titleVisibility: .visible) {
            ForEach(artistChoices) { artist in
                Button(artist.name) { selectedArtist = artist }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistView(artistId: artist.id) }
                .preferredColorScheme(.dark)
        }
    }

    private var background: some View {
        let colors = palette.isEmpty ? [AG.amber, AG.ember, Color.black] : palette
        let first = colors[0]
        let second = colors[min(1, colors.count - 1)]
        let third = colors[min(2, colors.count - 1)]
        let pulse = reduceMotion ? 0 : beat

        return ZStack {
            AG.bg

            RadialGradient(colors: [first.opacity(0.88), .clear], center: .topLeading, startRadius: 10, endRadius: 430)
                .scaleEffect(1 + pulse * 0.10, anchor: .topLeading)

            RadialGradient(colors: [second.opacity(0.72), .clear], center: .trailing, startRadius: 20, endRadius: 390)
                .scaleEffect(1 + pulse * 0.16, anchor: .trailing)
                .opacity(0.58 + pulse * 0.30)

            RadialGradient(colors: [third.opacity(0.58), AG.bg.opacity(0.92)], center: .bottomLeading, startRadius: 0, endRadius: 520)
                .scaleEffect(1 + pulse * 0.08, anchor: .bottomLeading)

            LinearGradient(colors: [.black.opacity(0.08), AG.bg.opacity(0.50), AG.bg.opacity(0.92)], startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: beat)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Свернуть плеер")

            Spacer()

            VStack(spacing: 4) {
                Capsule().fill(.white.opacity(0.50)).frame(width: 36, height: 5)
                Text("СЕЙЧАС ИГРАЕТ")
                    .font(AG.text(9, .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(width: 150, height: 44)
            .contentShape(Rectangle())
            .gesture(closeGesture)
            .accessibilityHint("Потяните вниз, чтобы свернуть")

            Spacer()

            Menu {
                Button { player.stopAndClear(); close() } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
                    .contentShape(Circle())
            }
        }
    }

    private func animatedCover(side: CGFloat) -> some View {
        let pulse = reduceMotion ? 0 : beat
        return ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(AngularGradient(colors: [AG.amber, AG.ember, .clear, AG.amber], center: .center))
                .frame(width: side + 18, height: side + 18)
                .blur(radius: 18 + pulse * 8)
                .opacity(player.isPlaying ? 0.32 + pulse * 0.28 : 0.16)
                .scaleEffect(0.98 + pulse * 0.06)

            artwork
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.48), radius: 24, y: 15)
                .scaleEffect(player.isPlaying ? 1 : 0.975)
        }
        .frame(width: side, height: side)
        .animation(reduceMotion ? nil : .linear(duration: 0.10), value: beat)
        .animation(.smooth(duration: 0.28), value: player.isPlaying)
        .id(track?.id)
        .transition(.opacity)
    }

    @ViewBuilder private var artwork: some View {
        if let track, let image = LibraryStore.cachedArtworkImage(for: track) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let cover = track?.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { fallbackArtwork }
            }
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 70, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var metadata: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(track?.title ?? "Sonivo")
                    .font(AG.display(24, .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: openArtist) {
                    HStack(spacing: 5) {
                        Text(track?.artist ?? "")
                            .font(AG.text(15, .semibold))
                            .lineLimit(1)
                        if resolvingArtist {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .black))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil || resolvingArtist)
            }

            if let track {
                Button { library.toggleFavorite(track) } label: {
                    Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.thinMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.progress }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.01))
                .tint(.white)
            HStack {
                Text(player.formatted(player.progress))
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - player.progress)))
            }
            .font(AG.text(11, .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var controls: some View {
        HStack {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
            Spacer()
            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 31, weight: .black))
                    .foregroundStyle(.black.opacity(0.86))
                    .frame(width: 76, height: 76)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.30), radius: 16, y: 8)
                    .contentShape(Circle())
            }
            Spacer()
            Button(action: nextTrack) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var bottomTools: some View {
        HStack {
            Image(systemName: "quote.bubble")
            Spacer()
            AirPlayButtonView().frame(width: 44, height: 44)
            Spacer()
            Image(systemName: "waveform")
            Spacer()
            Image(systemName: "list.bullet")
        }
        .font(.system(size: 19, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
        .frame(height: 44)
        .padding(.horizontal, 18)
    }

    private func togglePlayback() {
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.togglePlay()
    }

    private func previousTrack() {
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.previous()
    }

    private func nextTrack() {
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.next()
    }

    private func openArtist() {
        guard let track else { return }
        resolvingArtist = true
        Task {
            let resolved = await YandexMusicService.shared.resolvePlayerArtists(for: track)
            artistChoices = resolved
            resolvingArtist = false
            if resolved.count == 1 { selectedArtist = resolved[0] }
            else if resolved.count > 1 { showArtistChoice = true }
        }
    }

    private func close() {
        guard !dismissing else { return }
        dismissing = true
        isPresented = false
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragY = min(value.translation.height * 0.78, 180)
            }
            .onEnded { value in
                if value.translation.height > 70 || value.predictedEndTranslation.height > 125 {
                    close()
                } else {
                    withAnimation(.smooth(duration: 0.22)) { dragY = 0 }
                }
            }
    }
}
