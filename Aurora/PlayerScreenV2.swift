import SwiftUI
import UIKit

struct PlayerScreenV2: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var library = LibraryStore.shared
    @Binding var isPresented: Bool

    @State private var dragY: CGFloat = 0
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var showArtistChoice = false
    @State private var resolvingArtist = false

    private var track: Track? { player.currentTrack }
    private var palette: [Color] { track?.palette ?? Palette.seeded(42).colors }

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
        .gesture(closeGesture)
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
        ZStack {
            AG.bg
            AnimatedMeshBackground(palette: palette)
                .opacity(0.52)
                .blur(radius: 28)
            LinearGradient(colors: [.black.opacity(0.15), AG.bg.opacity(0.72), AG.bg], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.ultraThinMaterial).opacity(0.20)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: Circle())
            }
            Spacer()
            VStack(spacing: 4) {
                Capsule().fill(.white.opacity(0.28)).frame(width: 34, height: 4)
                Text("СЕЙЧАС ИГРАЕТ").font(AG.text(9, .heavy)).tracking(1.5).foregroundStyle(AG.inkMuted)
            }
            Spacer()
            Menu {
                Button { player.stopAndClear(); close() } label: { Label("Остановить", systemImage: "stop.fill") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.thinMaterial, in: Circle())
            }
        }
    }

    private func animatedCover(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(AngularGradient(colors: [AG.amber, AG.ember, .clear, AG.amber], center: .center))
                .frame(width: side + 24, height: side + 24)
                .blur(radius: player.isPlaying ? 20 : 28)
                .opacity(player.isPlaying ? 0.48 : 0.20)
                .scaleEffect(player.isPlaying ? 1.02 : 0.94)

            artwork
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(AG.hairline))
                .shadow(color: .black.opacity(0.5), radius: 26, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.975)
        }
        .frame(width: side, height: side)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: player.isPlaying)
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
        } else { fallbackArtwork }
    }

    private var fallbackArtwork: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: 70, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        }
    }

    private var metadata: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(track?.title ?? "Sonivo")
                    .font(AG.display(24, .heavy))
                    .foregroundStyle(AG.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: openArtist) {
                    HStack(spacing: 5) {
                        Text(track?.artist ?? "")
                            .font(AG.text(15, .semibold))
                            .lineLimit(1)
                        if resolvingArtist { ProgressView().controlSize(.mini).tint(AG.amber) }
                        else { Image(systemName: "chevron.right").font(.system(size: 9, weight: .black)) }
                    }
                    .foregroundStyle(AG.amber)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track == nil || resolvingArtist)
            }

            if let track {
                Button { library.toggleFavorite(track) } label: {
                    Image(systemName: library.isTrackFavorite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(library.isTrackFavorite(track) ? AG.ember : AG.ink)
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { player.progress }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.01))
                .tint(AG.amber)
            HStack {
                Text(player.formatted(player.progress))
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - player.progress)))
            }
            .font(AG.text(11, .medium).monospacedDigit())
            .foregroundStyle(AG.inkMuted)
        }
    }

    private var controls: some View {
        HStack {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 27)).frame(width: 62, height: 62) }
            Spacer()
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 31, weight: .black))
                    .foregroundStyle(.black.opacity(0.86))
                    .frame(width: 76, height: 76)
                    .background(AG.emberGradient, in: Circle())
                    .shadow(color: AG.ember.opacity(0.45), radius: 18, y: 8)
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 27)).frame(width: 62, height: 62) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(AG.ink)
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
        .foregroundStyle(AG.ink.opacity(0.78))
        .frame(height: 44)
        .padding(.horizontal, 18)
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.90)) { isPresented = false }
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width), value.translation.height > 0 {
                    dragY = value.translation.height * 0.82
                }
            }
            .onEnded { value in
                if value.translation.height > 105 || value.predictedEndTranslation.height > 190 { close() }
                else { withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { dragY = 0 } }
            }
    }
}
