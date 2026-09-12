import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation
import AVKit

struct PlayerScreenV2: View {
    @State private var player = ActivePlayerPresentation()
    @State private var library = LibraryStore.shared
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeModal: ActivePlayerModal?
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var resolvingArtist = false
    @State private var showLyricsMode = false
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var coverDragX: CGFloat = 0
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String?
    @State private var videoShotURL: URL?
    @State private var isVideoShotEnabled = UserDefaults.standard.object(forKey: "aurora_videoshot_enabled") as? Bool ?? true
    @State private var videoLooperPlayer: AVQueuePlayer?
    @State private var videoLooper: AVPlayerLooper?
    @State private var artworkPaletteColors: [Color] = []
    @State private var paletteTrackId: UUID?
    private let tapSide: CGFloat = AG.tapTarget

    enum ActivePlayerModal: String, Identifiable {
        case queue, equalizer, sleepTimer, settings, quality, artistSelection, lyrics
        var id: String { rawValue }
    }

    init(isPresented: Binding<Bool>) { _isPresented = isPresented }
    private var track: Track? { player.currentTrack }
    private var displayedMetadataTrack: Track? { player.displayTrack }
    private var palette: [Color] {
        if !artworkPaletteColors.isEmpty { return artworkPaletteColors }
        if let colors = track?.palette, !colors.isEmpty { return colors }
        return Palette.seeded(42).colors
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, geo.size.height * 0.40, 360)
            ZStack {
                background.frame(width: geo.size.width, height: geo.size.height).clipped().ignoresSafeArea()
                VStack(spacing: 0) {
                    topHeader.padding(.top, max(geo.safeAreaInsets.top, 48)).padding(.horizontal, 24)
                    Spacer(minLength: 8)
                    artworkStage(side: side).frame(maxWidth: .infinity)
                    Spacer(minLength: 8)
                    if let waveMessage {
                        Text(waveMessage).font(AG.text(.caption, .semibold)).foregroundStyle(AG.ink)
                            .padding(.horizontal, 14).padding(.vertical, 7).glassCapsule().padding(.bottom, 4)
                    }
                    lowerDeck.padding(.horizontal, 24).padding(.bottom, 12)
                }
            }
        }
        .background(Color.black.ignoresSafeArea()).preferredColorScheme(.dark)
        .simultaneousGesture(DragGesture().onEnded { value in
            if value.translation.height > 80 && value.predictedEndTranslation.height > 120 { close() }
        })
        .sheet(item: $activeModal) { modal in
            NavigationStack {
                switch modal {
                case .queue: QueueSheetView()
                case .equalizer: PlayerEQSheetView()
                case .sleepTimer: SleepTimerSheetView()
                case .settings: SettingsView()
                case .quality: PlayerQualityModalView(player: player, onDismiss: { activeModal = nil })
                case .artistSelection: artistSelectionSheet
                case .lyrics:
                    LyricsView(lyrics: lyrics, isLoading: lyricsLoading)
                        .navigationTitle("Текст песни").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
                }
            }.preferredColorScheme(.dark)
        }
        .sheet(item: $selectedArtist) { artist in NavigationStack { ArtistView(artistId: artist.id) }.preferredColorScheme(.dark) }
        .task { await player.observeTimeline() }
        .task(id: track?.id) {
            async let p: () = refreshPalette()
            async let l: () = loadLyrics()
            async let v: () = loadVideoShot()
            _ = await (p, l, v)
        }
        .onChange(of: player.isPlaying) { _, playing in playing ? videoLooperPlayer?.play() : videoLooperPlayer?.pause() }
        .onDisappear { teardownVideoLooper() }
    }

    private var isFullScreenVideoShot: Bool {
        isVideoShotEnabled && videoLooperPlayer != nil
    }

    private var background: some View {
        ZStack {
            if isFullScreenVideoShot, let videoLooperPlayer {
                VideoShotPlayerView(player: videoLooperPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaledToFill()
                    .clipped()
                    .ignoresSafeArea()

                // Элегантная кинематографичная виньетка:
                // Верх — легкое затемнение под хедер; центр — кристально чистое видео; низ — глубокое затемнение под контролы
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0.0),
                    .init(color: .black.opacity(0.10), location: 0.18),
                    .init(color: .clear, location: 0.35),
                    .init(color: .clear, location: 0.50),
                    .init(color: .black.opacity(0.45), location: 0.68),
                    .init(color: .black.opacity(0.85), location: 0.88),
                    .init(color: .black.opacity(0.96), location: 1.0)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            } else if reduceMotion || scenePhase != .active {
                gradientBackground
                LinearGradient(stops: [.init(color: .black.opacity(0.18), location: 0),
                                       .init(color: .black.opacity(0.68), location: 0.78),
                                       .init(color: .black.opacity(0.94), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                artwork.frame(maxWidth: .infinity, maxHeight: .infinity).blur(radius: 64).scaleEffect(1.2).opacity(0.4)
                AnimatedMeshBackground(palette: Array(backgroundColors.prefix(3))).opacity(0.55)
                LinearGradient(stops: [.init(color: .black.opacity(0.18), location: 0),
                                       .init(color: .black.opacity(0.68), location: 0.78),
                                       .init(color: .black.opacity(0.94), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }.allowsHitTesting(false)
    }
    private var backgroundColors: [Color] { palette.isEmpty ? [AG.amber, AG.ember] : palette }
    private var gradientBackground: some View {
        let colors = backgroundColors
        return LinearGradient(colors: [colors[0].opacity(0.65), colors[min(1, colors.count - 1)].opacity(0.38), .black],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var topHeader: some View {
        HStack {
            GlassIconButton(systemImage: "chevron.down", tint: AG.inkMuted, weight: .bold,
                            accessibilityLabel: "Свернуть плеер", action: close)
            Spacer()
            Menu {
                Button { withAnimation(AG.spring) { showLyricsMode.toggle() } } label: { Label("Текст песни", systemImage: "quote.bubble") }
                Button { openModal(.queue) } label: { Label("Очередь", systemImage: "list.bullet") }
                Button { openModal(.equalizer) } label: { Label("Эквалайзер", systemImage: "slider.vertical.3") }.disabled(player.isV2Enabled)
                Button { openModal(.sleepTimer) } label: { Label("Таймер сна", systemImage: "timer") }.disabled(player.isV2Enabled)
                Button { openModal(.settings) } label: { Label("Настройки", systemImage: "gearshape") }
                Button {
                    Task {
                        if await SonivoDiagnostics.shared.sendReportToTelegram() {
                            waveMessage = "✅ Диагностика отправлена"
                            try? await Task.sleep(for: .seconds(2.5)); waveMessage = nil
                        }
                    }
                } label: { Label("Отправить логи", systemImage: "paperplane") }
                Button(role: .destructive) { player.stopAndClear(); close() } label: { Label("Остановить и очистить", systemImage: "stop.fill") }
            } label: {
                Image(systemName: "ellipsis").font(AG.glyph(.bold)).foregroundStyle(AG.inkMuted)
                    .frame(width: tapSide, height: tapSide).contentShape(Circle())
            }.glassCircle().accessibilityLabel("Ещё")
        }.frame(minHeight: tapSide)
    }

    private func artworkStage(side: CGFloat) -> some View {
        ZStack {
            if isFullScreenVideoShot && !showLyricsMode {
                // В полноэкранном режиме видеошота центральный квадрат прозрачен,
                // открывая полный обзор красивого вертикального видео лейбла
                Color.clear
                    .frame(width: side, height: side)
            } else {
                artwork
                    .frame(width: side, height: side)
                    .scaledToFill()
                    .clipped()
            }
            if !isFullScreenVideoShot && !showLyricsMode {
                AutoMixTransitionOverlay(side: side)
            }
            if showLyricsMode { lyricsOverlay(side: side) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    .white.opacity(isFullScreenVideoShot && !showLyricsMode ? 0.0 : (player.isTransitionActive ? 0.32 : 0.14)),
                    lineWidth: 1
                )
        )
        .shadow(color: .white.opacity(isFullScreenVideoShot ? 0 : (player.isTransitionActive ? 0.22 : 0)), radius: 22)
        .shadow(
            color: (artworkPaletteColors.first ?? .black).opacity(isFullScreenVideoShot ? 0 : (player.isPlaying ? 0.40 : 0.15)),
            radius: player.isPlaying ? 24 : 8,
            y: player.isPlaying ? 12 : 4
        )
        .scaleEffect(player.isPlaying ? 1 : 0.88).offset(x: coverDragX)
        .rotationEffect(.degrees(Double(coverDragX / 24)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard !player.isTransitionActive, abs(value.translation.width) > abs(value.translation.height) else { return }
                coverDragX = value.translation.width / (1 + abs(value.translation.width) * 0.003)
            }
            .onEnded { value in
                guard !player.isTransitionActive, abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(AG.spring) { coverDragX = 0 }; return
                }
                if value.translation.width < -50 {
                    withAnimation(AG.spring) { coverDragX = -side * 1.2 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { nextTrack(); coverDragX = side * 1.2; withAnimation(AG.spring) { coverDragX = 0 } }
                } else if value.translation.width > 50 {
                    withAnimation(AG.spring) { coverDragX = side * 1.2 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { previousTrack(); coverDragX = -side * 1.2; withAnimation(AG.spring) { coverDragX = 0 } }
                } else { withAnimation(AG.spring) { coverDragX = 0 } }
            })
        .animation(.easeInOut(duration: 0.35), value: player.isTransitionActive)
        .animation(AG.slowSpring, value: player.isPlaying)
    }

    private func lyricsOverlay(side: CGFloat) -> some View {
        ZStack {
            Color.black.opacity(0.60)
            VStack {
                HStack { Spacer(); Button { openModal(.lyrics) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").padding(14) } }
                Spacer()
            }
            VStack(spacing: 14) {
                if lyricsLoading { ProgressView().tint(.white); Text("Загрузка текста…").foregroundStyle(AG.inkMuted) }
                else {
                    let pair = currentLyricsPair
                    Text(pair.current).font(AG.display(.largeTitle, .heavy)).foregroundStyle(AG.ink)
                        .multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.7).padding(.horizontal, 20)
                    if let next = pair.next { Text(next).font(AG.text(.body, .semibold)).foregroundStyle(AG.inkFaint).lineLimit(2) }
                }
            }
        }.frame(width: side, height: side)
    }
    private var currentLyricsPair: (current: String, next: String?) {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return ("Слова песни", nil) }
        var index = 0
        for (i, line) in lines.enumerated() { if line.startTime <= max(0, player.progress - 0.12) { index = i } else { break } }
        return (lines[index].text, index + 1 < lines.count ? lines[index + 1].text : nil)
    }

    @ViewBuilder private var artwork: some View {
        if let track, let image = LibraryStore.cachedArtworkImage(for: track) { Image(uiImage: image).resizable().scaledToFill() }
        else if let raw = track?.coverURL, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { fallbackArtwork }
            }
        } else { fallbackArtwork }
    }
    private var fallbackArtwork: some View {
        ZStack { LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.system(size: 70, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
    }

    private var lowerDeck: some View {
        VStack(spacing: 16) {
            metadataRow
            PlayerTimelineSection { centerStatusLabel }
            transportControls
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").foregroundStyle(AG.inkMuted)
                NativeVolumeSlider().frame(height: 32)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(AG.inkMuted)
            }.padding(.horizontal, 4)
            HStack {
                GlassIconButton(systemImage: showLyricsMode ? "quote.bubble.fill" : "quote.bubble", tint: showLyricsMode ? AG.amber : AG.inkMuted, accessibilityLabel: "Текст песни") { withAnimation(AG.spring) { showLyricsMode.toggle() } }
                Spacer(); AirPlayButtonView().frame(width: tapSide, height: tapSide).glassCircle(); Spacer()
                GlassIconButton(systemImage: "list.bullet", tint: AG.inkMuted, accessibilityLabel: "Очередь") { openModal(.queue) }
            }.padding(.horizontal, 28)
        }
    }
    private var metadataRow: some View {
        let current = displayedMetadataTrack ?? track
        let favorite = current.map(library.isTrackFavorite) ?? false
        return HStack(spacing: 14) {
            Button(action: openArtist) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: current?.title ?? "Не играет", font: AG.rounded(.title2, .bold), color: AG.ink, height: 28)
                    MarqueeText(text: current?.artist ?? "", font: AG.rounded(.body, .medium), color: AG.inkMuted, height: 22)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).disabled(current == nil || resolvingArtist)
            if videoShotURL != nil { GlassIconButton(systemImage: isVideoShotEnabled ? "video.fill" : "video.slash.fill", tint: isVideoShotEnabled ? AG.positive : AG.inkMuted, accessibilityLabel: "Видео-шот", action: toggleVideoShot) }
            if current?.isStream == true { GlassIconButton(systemImage: "dot.radiowaves.left.and.right", tint: waveActive ? AG.amber : AG.inkMuted, accessibilityLabel: "Моя волна", action: startTrackWave).disabled(waveLoading) }
            Button {
                guard let current else { return }; library.toggleFavorite(current)
            } label: {
                Image(systemName: favorite ? "heart.fill" : "heart").foregroundStyle(favorite ? AG.heart : AG.inkMuted)
                    .frame(width: tapSide, height: tapSide)
            }.glassCircle().disabled(current == nil)
        }
    }
    @ViewBuilder private var centerStatusLabel: some View {
        if player.isTransitionActive {
            AutoMixBadge().transition(.opacity)
        } else {
            qualityBadgeButton.transition(.opacity)
        }
    }
    private var qualityBadgeButton: some View {
        Button { openModal(.quality) } label: {
            HStack(spacing: 4) { Image(systemName: "waveform"); Text(qualityBadgeLabel) }
                .font(AG.text(.caption2, .semibold)).foregroundStyle(AG.ink.opacity(0.85)).padding(.horizontal, 10).padding(.vertical, 6)
        }.buttonStyle(.plain).glassCapsule(interactive: true)
    }
    private var qualityBadgeLabel: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
            return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"
        }
        if bitrate >= 320 { return "HQ \(bitrate) kbps" }
        if bitrate > 0 { return "\(bitrate) kbps" }
        if !codec.isEmpty { return codec.uppercased() }
        return player.audioQuality.badgeText
    }
    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: previousTrack) { Image(systemName: "backward.fill").font(.system(.largeTitle, weight: .bold)).frame(maxWidth: .infinity, minHeight: 52) }
            Button(action: togglePlayback) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40, weight: .black)).frame(maxWidth: .infinity, minHeight: 56) }.disabled(player.isLoading)
            Button(action: nextTrack) { Image(systemName: "forward.fill").font(.system(.largeTitle, weight: .bold)).frame(maxWidth: .infinity, minHeight: 52) }
        }.foregroundStyle(AG.ink).buttonStyle(TactileButtonStyle(scale: 0.86))
    }

    private var artistSelectionSheet: some View {
        List(artistChoices) { artist in Button(artist.name) { activeModal = nil; selectedArtist = artist } }
            .navigationTitle("Исполнители").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
    }
}

struct PlayerQualityModalView: View {
    let player: ActivePlayerPresentation
    let onDismiss: () -> Void

    @State private var showingSettings = false

    var body: some View {
        Group {
            if showingSettings {
                qualitySettingsList
            } else {
                appleMusicQualityCard
            }
        }
    }

    private var appleMusicQualityCard: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 58, height: 58)
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 16)

            Text(currentQualityTitle)
                .font(.system(size: 24, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Text(currentQualityDescription)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let formatDetail = currentQualityFormatDetail {
                    Text(formatDetail)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                }
            }

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showingSettings = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Настройки качества звука")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    onDismiss()
                } label: {
                    Text("OK")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .padding(.top, 8)
        .presentationDetents([.height(370), .medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var qualitySettingsList: some View {
        List {
            Section {
                ForEach(AudioQuality.allCases) { quality in
                    Button {
                        player.selectQuality(quality)
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showingSettings = false
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(quality.label)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(quality.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            Spacer()
                            if player.audioQuality == quality {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.white)
                                    .fontWeight(.bold)
                            }
                        }
                    }
                }
            } header: {
                Text("Предпочитаемое качество звука")
            }
        }
        .navigationTitle("Качество звука")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showingSettings = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Назад")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") {
                    onDismiss()
                }
            }
        }
    }

    private var currentQualityTitle: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
            return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless"
        }
        if bitrate >= 320 { return "Высокое качество (HQ)" }
        if bitrate > 0 { return "Стандартное качество" }
        return player.audioQuality.badgeText
    }

    private var currentQualityDescription: String {
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("flac") || codec.contains("alac") || codec.contains("wav") {
            return "Аудио без потерь (Lossless) воспроизводится с оригинальным студийным качеством записи без потери деталей звука."
        }
        if bitrate >= 320 || codec.contains("mp3") || codec.contains("aac") {
            return "Аудио высокого качества воспроизводится с оптимизированным сжатием данных для быстрого и стабильного воспроизведения."
        }
        return "Качество звука настраивается автоматически или в соответствии с вашими предпочтениями."
    }

    private var currentQualityFormatDetail: String? {
        let codec = player.currentCodec?.uppercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("FLAC") || codec.contains("ALAC") || codec.contains("WAV") {
            let brText = bitrate > 0 ? "\(bitrate) кбит/с" : "до 1411 кбит/с"
            return "Формат: \(codec) • \(brText) • 16/24 бит, 44,1 кГц"
        }
        if !codec.isEmpty {
            let brText = bitrate > 0 ? "\(bitrate) кбит/с" : "320 кбит/с"
            return "Формат: \(codec) • \(brText)"
        }
        return nil
    }
    private var artistSelectionSheet: some View {
        List(artistChoices) { artist in Button(artist.name) { activeModal = nil; selectedArtist = artist } }
            .navigationTitle("Исполнители").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil } } }
    }

    private func updatePalette(from image: UIImage) async {
        let hexes = await Task.detached(priority: .utility) { LibraryStore.artworkPalette(from: image) }.value
        let colors = hexes.compactMap(Color.init(hex:)); guard !colors.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.85)) { artworkPaletteColors = colors }
    }
    private func refreshPalette() async {
        guard let track, paletteTrackId != track.id else { return }; paletteTrackId = track.id
        if let image = LibraryStore.cachedArtworkImage(for: track) { await updatePalette(from: image); return }
        if let raw = track.coverURL, let url = URL(string: raw), let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) { await updatePalette(from: image) }
        else if !track.palette.isEmpty { artworkPaletteColors = track.palette }
    }
    private func loadLyrics() async {
        lyrics = nil; guard let requested = track else { lyricsLoading = false; return }
        lyricsLoading = true; let result = try? await LyricsService.shared.fetchLyrics(for: requested)
        guard !Task.isCancelled, player.currentTrack?.id == requested.id else { return }; lyrics = result; lyricsLoading = false
    }
    private func loadVideoShot() async {
        guard let track else { videoShotURL = nil; teardownVideoLooper(); return }
        let id = PlayerCore.yandexTrackID(from: track); guard !id.isEmpty else { videoShotURL = nil; teardownVideoLooper(); return }
        let url = await YandexMusicService.shared.getVideoShotUrl(for: id)
        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        videoShotURL = url; if isVideoShotEnabled, let url { setupVideoLooper(url: url) } else { teardownVideoLooper() }
    }
    private func setupVideoLooper(url: URL) {
        teardownVideoLooper()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        videoLooper = AVPlayerLooper(player: player, templateItem: item)
        videoLooperPlayer = player
        player.play()
    }
    private func teardownVideoLooper() { videoLooperPlayer?.pause(); videoLooperPlayer = nil; videoLooper = nil }
    private func toggleVideoShot() { isVideoShotEnabled.toggle(); UserDefaults.standard.set(isVideoShotEnabled, forKey: "aurora_videoshot_enabled"); if isVideoShotEnabled, let videoShotURL { setupVideoLooper(url: videoShotURL) } else { teardownVideoLooper() } }
    private func openModal(_ modal: ActivePlayerModal) { Haptics.tap(.light); activeModal = modal }
    private func togglePlayback() { Haptics.tap(.medium); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.togglePlay() }
    private func previousTrack() { Haptics.tap(.light); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.previous() }
    private func nextTrack() { Haptics.tap(.light); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.next() }
    private func close() { Haptics.tap(.light); isPresented = false }
    private func openArtist() {
        guard let track else { return }; resolvingArtist = true
        Task { let result = await YandexMusicService.shared.resolvePlayerArtists(for: track); resolvingArtist = false; artistChoices = result; if result.count == 1 { selectedArtist = result[0] } else if !result.isEmpty { activeModal = .artistSelection } }
    }
    private func startTrackWave() {
        guard let current = track else { return }; waveLoading = true
        Task {
            let tracks = await YandexMusicService.shared.buildTrackWave(from: current, target: 45); waveLoading = false
            guard !tracks.isEmpty else { return }; player.queue = player.isV2Enabled ? [current] + tracks.filter { $0.id != current.id } : tracks
            waveActive = true; waveMessage = "🌊 Моя волна запущена"; try? await Task.sleep(for: .seconds(2.5)); waveMessage = nil
        }
    }
}

struct PlayerTimelineSection<Center: View>: View {
    @State private var player = ActivePlayerPresentation()
    @State private var isScrubbing = false
    @State private var scrubProgress = 0.0
    @State private var lastFeedbackProgress = 0.0
    private let feedback = UISelectionFeedbackGenerator()
    private let center: Center
    init(@ViewBuilder center: () -> Center) { self.center = center() }
    private var effectiveProgress: Double { isScrubbing ? scrubProgress : player.progress }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let duration = max(player.duration, 0.01)
                let fraction = min(1, max(0, effectiveProgress / duration))
                let width = geo.size.width * fraction
                let height: CGFloat = isScrubbing ? 10 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.20)).frame(height: height)
                    Capsule().fill(.white).frame(width: max(height, width), height: height)
                    if isScrubbing { Circle().fill(.white).frame(width: 22, height: 22).offset(x: width - 11).shadow(radius: 6) }
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing { isScrubbing = true; feedback.prepare() }
                        let f = min(1, max(0, value.location.x / max(geo.size.width, 1))); scrubProgress = f * duration
                        if abs(f - lastFeedbackProgress) > 0.04 { Haptics.scrubTick(feedback); lastFeedbackProgress = f }
                    }
                    .onEnded { value in
                        let f = min(1, max(0, value.location.x / max(geo.size.width, 1))); player.seek(to: f * duration)
                        withAnimation(AG.spring) { isScrubbing = false }
                    })
            }.frame(height: 24)
            HStack {
                Text(player.formatted(effectiveProgress)).font(AG.text(.caption, .semibold).monospacedDigit()).foregroundStyle(AG.inkMuted)
                Spacer(); center; Spacer()
                Text("-" + player.formatted(max(0, player.duration - effectiveProgress))).font(AG.text(.caption, .semibold).monospacedDigit()).foregroundStyle(AG.inkMuted)
            }
        }.task { await player.observeTimeline() }.onChange(of: player.currentTrack?.id) { _, _ in isScrubbing = false }
    }
}

struct AutoMixBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title = "Mixing"
    private let sweepCycle: TimeInterval = 2.4

    var body: some View {
        Group {
            if reduceMotion {
                mark(sweep: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let phase = time.truncatingRemainder(dividingBy: sweepCycle) / sweepCycle
                    mark(sweep: CGFloat(phase))
                }
            }
        }
        .accessibilityLabel(Text(title))
        .allowsHitTesting(false)
    }

    private func mark(sweep: CGFloat?) -> some View {
        let label = Text(title)
            .font(.system(size: 13, weight: .semibold, design: .default))

        return label
            .foregroundStyle(.white.opacity(0.85))
            .overlay {
                if let sweep {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        let band = max(width * 0.55, 24)
                        let travel = width + band * 2

                        LinearGradient(
                            colors: [.clear, .white.opacity(0.40), .white, .white.opacity(0.40), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: band)
                        .offset(x: -band + sweep * travel)
                        .frame(width: width, height: geo.size.height, alignment: .leading)
                        .clipped()
                        .blendMode(.plusLighter)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
            .shadow(color: .white.opacity(0.40), radius: 6)
            .shadow(color: .white.opacity(0.15), radius: 12)
            .fixedSize()
            .compositingGroup()
    }
}

struct NativeVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero); view.showsRouteButton = false; view.showsVolumeSlider = true
        DispatchQueue.main.async { style(view) }; return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) { DispatchQueue.main.async { style(uiView) } }
    private func style(_ view: MPVolumeView) {
        for case let slider as UISlider in view.subviews {
            slider.isContinuous = true; slider.minimumTrackTintColor = .white.withAlphaComponent(0.85); slider.maximumTrackTintColor = .white.withAlphaComponent(0.25)
        }
    }
}

struct VideoShotPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> PlayerUIView { let view = PlayerUIView(); view.player = player; return view }
    func updateUIView(_ uiView: PlayerUIView, context: Context) { uiView.player = player }
    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVPlayer? { get { playerLayer.player } set { playerLayer.player = newValue; playerLayer.videoGravity = .resizeAspectFill } }
    }
}

#Preview("Full player") { PlayerScreenV2(isPresented: .constant(true)) }
#Preview("Timeline") { PlayerTimelineSection { AutoMixBadge() }.padding() }
