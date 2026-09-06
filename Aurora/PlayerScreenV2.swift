// Path: Aurora/PlayerScreenV2.swift

import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation
import AVKit

struct PlayerScreenV2: View {
    @State private var player = ActivePlayerPresentation()
    @State private var library = LibraryStore.shared
    @Binding var isPresented: Bool
    init(isPresented: Binding<Bool>) { self._isPresented = isPresented }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let tapSide: CGFloat = AG.tapTarget
    @State private var artistChoices: [PlayerArtistLink] = []
    @State private var selectedArtist: PlayerArtistLink?
    @State private var resolvingArtist = false
    enum ActivePlayerModal: String, Identifiable {
        case queue, equalizer, sleepTimer, settings, quality, artistSelection, lyrics
        var id: String { rawValue }
    }
    @State private var activeModal: ActivePlayerModal? = nil
    @State private var showLyricsMode = false
    @State private var waveLoading = false
    @State private var waveActive = false
    @State private var waveMessage: String? = nil
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var coverDragX: CGFloat = 0
    @State private var videoShotURL: URL? = nil
    @State private var isVideoShotEnabled: Bool = UserDefaults.standard.object(forKey: "aurora_videoshot_enabled") as? Bool ?? true
    @State private var videoLooperPlayer: AVQueuePlayer? = nil
    @State private var videoLooper: AVPlayerLooper? = nil
    @State private var artworkPaletteColors: [Color] = []
    @State private var paletteTrackId: UUID? = nil
    private var track: Track? { player.currentTrack }
    private var displayedMetadataTrack: Track? { player.displayTrack }
    private var palette: [Color] {
        if !artworkPaletteColors.isEmpty { return artworkPaletteColors }
        if let p = track?.palette, !p.isEmpty { return p }
        return Palette.seeded(42).colors
    }
    private func updatePalette(from image: UIImage) async {
        let hexes = await Task.detached(priority: .utility) { LibraryStore.artworkPalette(from: image) }.value
        let colors = hexes.compactMap { Color(hex: $0) }
        guard !colors.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.85)) { artworkPaletteColors = colors }
    }
    private func refreshPalette() async {
        guard let track, paletteTrackId != track.id else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        paletteTrackId = track.id
        if let image = LibraryStore.cachedArtworkImage(for: track) {
            await updatePalette(from: image)
            return
        }
        if let cover = track.coverURL, let url = URL(string: cover),
           let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
            guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
            await updatePalette(from: image)
            return
        }
        let fallback = track.palette
        guard !fallback.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.85)) { artworkPaletteColors = fallback }
    }
    var body: some View {
        GeometryReader { geo in
            let coverSide = min(geo.size.width - 64, geo.size.height * 0.40, 360)
            ZStack {
                ZStack {
                    if reduceMotion || scenePhase != .active || (isVideoShotEnabled && videoLooperPlayer != nil) {
                        artworkGradientBackground
                        contrastProtectionVignette
                    } else {
                        artwork.frame(width: geo.size.width, height: geo.size.height)
                            .blur(radius: 64).scaleEffect(1.20).opacity(0.40)
                        AnimatedMeshBackground(palette: backgroundColors).opacity(0.55)
                        contrastProtectionVignette
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height).clipped().ignoresSafeArea()
                let topInset = max(geo.safeAreaInsets.top, 48)
                VStack(spacing: 0) {
                    topHeader.padding(.top, topInset).padding(.horizontal, 24)
                    Spacer(minLength: 8)
                    artworkStage(side: coverSide).frame(maxWidth: .infinity).transition(.opacity)
                    Spacer(minLength: 8)
                    if let waveMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(AG.text(.footnote, .bold)).foregroundStyle(AG.amber)
                            Text(waveMessage).font(AG.text(.caption, .semibold)).foregroundStyle(AG.ink)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7).glassCapsule()
                        .transition(.move(edge: .bottom).combined(with: .opacity)).padding(.bottom, 4)
                    }
                    appleMusicLowerDeck.padding(.horizontal, 24).padding(.bottom, 12)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .background(Color.black.ignoresSafeArea()).preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: player.isTransitionActive)
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
                case .quality: audioQualitySheetContent
                case .artistSelection: artistSelectionSheetContent
                case .lyrics:
                    NavigationStack {
                        LyricsView(lyrics: lyrics, isLoading: lyricsLoading)
                            .navigationTitle("Текст песни").navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Закрыть") { activeModal = nil }.foregroundStyle(AG.amber)
                                }
                            }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistView(artistId: artist.id) }.preferredColorScheme(.dark)
        }
        .task { await player.observeTimeline() }
        .task(id: track?.id) {
            await refreshPalette()
            guard !Task.isCancelled else { return }
            await loadLyrics()
            guard !Task.isCancelled else { return }
            await loadVideoShot()
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying { videoLooperPlayer?.play() } else { videoLooperPlayer?.pause() }
        }
        .onDisappear { teardownVideoLooper() }
    }
    private var backgroundColors: [Color] {
        let source = palette
        return source.isEmpty ? [AG.amber, AG.ember] : Array(source.prefix(3))
    }
    private var artworkGradientBackground: some View {
        let colors = backgroundColors
        let primary = colors[0]
        let secondary = colors.count > 1 ? colors[1] : primary
        let tertiary = colors.count > 2 ? colors[2] : secondary
        return ZStack {
            LinearGradient(stops: [
                .init(color: primary.opacity(0.62), location: 0.00),
                .init(color: secondary.opacity(0.42), location: 0.36),
                .init(color: tertiary.opacity(0.20), location: 0.66),
                .init(color: .black.opacity(0.96), location: 1.00)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [secondary.opacity(0.28), .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 720)
        }
        .compositingGroup().ignoresSafeArea().allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.70), value: colors)
    }
    private var contrastProtectionVignette: some View {
        LinearGradient(stops: [
            .init(color: Color.black.opacity(0.45), location: 0.0),
            .init(color: Color.black.opacity(0.10), location: 0.20),
            .init(color: Color.black.opacity(0.18), location: 0.50),
            .init(color: Color.black.opacity(0.68), location: 0.78),
            .init(color: Color.black.opacity(0.92), location: 1.0)
        ], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
    }
    private var topHeader: some View {
        HStack(alignment: .center) {
            GlassIconButton(systemImage: "chevron.down", tint: AG.inkMuted, weight: .bold,
                            accessibilityLabel: "Свернуть плеер", action: close)
            Spacer()
            Menu {
                Section("Плеер") {
                    Button { withAnimation(AG.spring) { showLyricsMode.toggle() } } label: {
                        Label(showLyricsMode ? "Скрыть текст песни" : "Текст песни", systemImage: "quote.bubble")
                    }
                }
                Section("Звук и очередь") {
                    Button { openModal(.queue) } label: { Label("Очередь воспроизведения", systemImage: "list.bullet") }
                    Button { openModal(.equalizer) } label: { Label("Эквалайзер", systemImage: "slider.vertical.3") }
                        .disabled(player.isV2Enabled)
                    Button { openModal(.sleepTimer) } label: { Label("Таймер сна", systemImage: "timer") }
                        .disabled(player.isV2Enabled)
                }
                Section("Приложение") {
                    Button { openModal(.settings) } label: { Label("Настройки", systemImage: "gearshape") }
                    Button {
                        Task {
                            let ok = await SonivoDiagnostics.shared.sendReportToTelegram()
                            if ok {
                                waveMessage = "✅ Диагностика отправлена в Telegram"
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                if waveMessage?.contains("Диагностика") == true { waveMessage = nil }
                            }
                        }
                    } label: { Label("Отправить логи в Telegram", systemImage: "paperplane") }
                }
                Section {
                    Button(role: .destructive) { player.stopAndClear(); close() } label: {
                        Label("Остановить и очистить", systemImage: "stop.fill")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(AG.glyph(.bold)).foregroundStyle(AG.inkMuted)
                    .frame(width: tapSide, height: tapSide).contentShape(Circle())
            }
            .glassCircle().accessibilityLabel("Ещё")
        }
        .frame(minHeight: tapSide)
    }
    private func artworkStage(side: CGFloat) -> some View {
        ZStack {
            if isVideoShotEnabled, let vp = videoLooperPlayer {
                VideoShotPlayerView(player: vp).frame(width: side, height: side).scaleEffect(1.34).clipped()
            } else {
                artwork.frame(width: side, height: side).scaledToFill().clipped()
            }
            // This overlay consumes legacy DSP state and must never label a V2 transition.
            if !player.isV2Enabled && !isVideoShotEnabled && !showLyricsMode { AutoMixTransitionOverlay(side: side) }
            if showLyricsMode {
                ZStack {
                    Color.black.opacity(0.60)
                    VStack {
                        HStack {
                            Spacer()
                            Button { Haptics.tap(.light); openModal(.lyrics) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(AG.text(.subheadline, .bold)).foregroundStyle(AG.ink.opacity(0.85))
                                    .padding(14).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityLabel("Развернуть текст")
                        }
                        Spacer()
                    }
                    VStack(spacing: 14) {
                        if lyricsLoading {
                            ProgressView().tint(.white).scaleEffect(1.15)
                            Text("Загрузка текста…").font(AG.rounded(.subheadline, .semibold)).foregroundStyle(AG.inkMuted)
                        } else {
                            let pair = inCoverLyricsCurrentAndNext
                            Text(pair.current).font(AG.display(.largeTitle, .heavy)).foregroundStyle(AG.ink)
                                .multilineTextAlignment(.center).lineLimit(4).lineSpacing(2).minimumScaleFactor(0.70)
                                .padding(.horizontal, 20).id(pair.current)
                                .transition(.opacity.combined(with: .scale(scale: 0.96))).animation(AG.spring, value: pair.current)
                            if let next = pair.next, !next.isEmpty {
                                Text(next).font(AG.text(.body, .semibold)).foregroundStyle(AG.inkFaint)
                                    .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 24)
                                    .animation(.easeInOut(duration: 0.25), value: next)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(width: side, height: side).transition(.opacity)
            }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1.0))
        .shadow(color: (artworkPaletteColors.first ?? Color.black).opacity(player.isPlaying ? 0.40 : 0.15),
                radius: player.isPlaying ? 24 : 8, x: 0, y: player.isPlaying ? 12 : 4)
        .scaleEffect(player.isPlaying ? 1.0 : 0.88).offset(x: coverDragX)
        .rotationEffect(.degrees(Double(coverDragX / 24)), anchor: .center)
        .gesture(DragGesture(minimumDistance: 15)
            .onChanged { val in
                guard abs(val.translation.width) > abs(val.translation.height) else { return }
                let translation = val.translation.width
                let damping: CGFloat = 1.0 + (abs(translation) * 0.003)
                coverDragX = translation / damping
            }
            .onEnded { val in
                guard abs(val.translation.width) > abs(val.translation.height) else {
                    withAnimation(AG.spring) { coverDragX = 0 }; return
                }
                let threshold: CGFloat = 50
                if val.translation.width < -threshold {
                    Haptics.tap(.medium)
                    withAnimation(AG.spring) { coverDragX = -side * 1.2 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        nextTrack(); coverDragX = side * 1.2
                        withAnimation(AG.spring) { coverDragX = 0 }
                    }
                } else if val.translation.width > threshold {
                    Haptics.tap(.medium)
                    withAnimation(AG.spring) { coverDragX = side * 1.2 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        previousTrack(); coverDragX = -side * 1.2
                        withAnimation(AG.spring) { coverDragX = 0 }
                    }
                } else { withAnimation(AG.spring) { coverDragX = 0 } }
            })
        .animation(AG.slowSpring, value: player.isPlaying)
    }
    private var inCoverLyricsCurrentAndNext: (current: String, next: String?) {
        guard let lines = lyrics?.lines, !lines.isEmpty else { return (current: "Слова песни", next: nil) }
        let currentTime = max(0, player.progress - 0.12)
        var activeIdx = 0
        for (i, line) in lines.enumerated() {
            if line.startTime <= currentTime { activeIdx = i } else { break }
        }
        let currentText = lines[activeIdx].text
        let nextText = (activeIdx + 1 < lines.count) ? lines[activeIdx + 1].text : nil
        return (current: currentText, next: nextText)
    }
    @ViewBuilder private var artwork: some View {
        if let track, let image = LibraryStore.cachedArtworkImage(for: track) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let cover = track?.coverURL, let url = URL(string: cover) {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { fallbackArtwork }
            }
        } else { fallbackArtwork }
    }
    private var fallbackArtwork: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note").font(.system(size: 70, weight: .semibold)).foregroundStyle(AG.ink.opacity(0.85))
        }
    }
    private var appleMusicLowerDeck: some View {
        VStack(spacing: 16) {
            trackMetadataRow
            PlayerTimelineSection { centerStatusLabel }
            transportControls
            volumeBar
            appleMusicBottomBar
        }
    }
    private var trackMetadataRow: some View {
        let current = displayedMetadataTrack ?? track
        let isFav = current.map { library.isTrackFavorite($0) } ?? false
        return HStack(alignment: .center, spacing: 14) {
            Button(action: openArtist) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: current?.title ?? "Не играет", font: AG.rounded(.title2, .bold), color: AG.ink, height: 28)
                    MarqueeText(text: current?.artist ?? "", font: AG.rounded(.body, .medium), color: AG.inkMuted, height: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(current == nil || resolvingArtist).accessibilityHint("Открыть страницу исполнителя")
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if videoShotURL != nil {
                        GlassIconButton(systemImage: isVideoShotEnabled ? "video.fill" : "video.slash.fill",
                            tint: isVideoShotEnabled ? AG.positive : AG.inkMuted,
                            accessibilityLabel: isVideoShotEnabled ? "Выключить видео-шот" : "Включить видео-шот", action: toggleVideoShot)
                    }
                    if let current, current.isStream {
                        GlassIconButton(systemImage: "dot.radiowaves.left.and.right", tint: waveActive ? AG.amber : AG.inkMuted,
                            accessibilityLabel: "Моя волна по треку", action: startTrackWave).disabled(waveLoading)
                    }
                    Button {
                        guard let current else { return }
                        Haptics.tap(.medium); library.toggleFavorite(current)
                    } label: {
                        Image(systemName: isFav ? "heart.fill" : "heart").font(AG.glyph(.semibold))
                            .foregroundStyle(isFav ? AG.heart : AG.inkMuted).contentTransition(.symbolEffect(.replace))
                            .frame(width: tapSide, height: tapSide).contentShape(Circle())
                    }
                    .buttonStyle(.plain).glassCircle().disabled(current == nil)
                    .accessibilityLabel(isFav ? "Удалить из избранного" : "В избранное")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
    @ViewBuilder private var centerStatusLabel: some View {
        if player.isTransitionActive {
            if player.isV2Enabled { Text(verbatim: "AutoMix V2").font(AG.text(.caption, .semibold)) }
            else { AutoMixBadge().transition(.opacity) }
        } else { qualityBadgeButton.transition(.opacity) }
    }
    private var qualityBadgeButton: some View {
        Button { openModal(.quality) } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform").font(AG.text(.caption2, .bold))
                Text(qualityBadgeLabel).font(AG.text(.caption2, .semibold)).lineLimit(1)
            }
            .foregroundStyle(AG.ink.opacity(0.85)).padding(.horizontal, 10).padding(.vertical, 6).contentShape(Capsule())
        }
        .buttonStyle(.plain).glassCapsule(interactive: true).disabled(player.isV2Enabled)
        .accessibilityLabel("Качество звука: \(qualityBadgeLabel)")
    }
    private var qualityBadgeLabel: String {
        if player.isV2Enabled { return "AutoMix V2" }
        let codec = player.currentCodec?.lowercased() ?? ""
        let bitrate = player.currentBitrate ?? 0
        if codec.contains("flac") { return bitrate >= 1000 ? "Hi-Res Lossless" : "Lossless" }
        if bitrate >= 320 { return "HQ \(bitrate) kbps" }
        if bitrate > 0 { return "\(bitrate) kbps" }
        return player.audioQuality.badgeText
    }
    private var transportControls: some View {
        HStack(spacing: 0) {
            Button(action: previousTrack) {
                Image(systemName: "backward.fill").font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(AG.ink).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.88)).accessibilityLabel("Предыдущий трек")
            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40, weight: .black))
                    .foregroundStyle(AG.ink).contentTransition(.symbolEffect(.replace.downUp))
                    .frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.82)).disabled(player.isLoading)
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")
            Button(action: nextTrack) {
                Image(systemName: "forward.fill").font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(AG.ink).frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.88)).accessibilityLabel("Следующий трек")
        }
        .padding(.vertical, 4)
    }
    private var volumeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(AG.text(.caption2, .bold)).foregroundStyle(AG.inkMuted)
            NativeVolumeSlider().frame(height: 32)
            Image(systemName: "speaker.wave.3.fill").font(AG.text(.caption2, .bold)).foregroundStyle(AG.inkMuted)
        }
        .padding(.horizontal, 4)
    }
    private var appleMusicBottomBar: some View {
        HStack(alignment: .center) {
            GlassIconButton(systemImage: showLyricsMode ? "quote.bubble.fill" : "quote.bubble",
                            tint: showLyricsMode ? AG.amber : AG.inkMuted, accessibilityLabel: "Текст песни") {
                withAnimation(AG.spring) { showLyricsMode.toggle() }
            }
            Spacer()
            AirPlayButtonView().frame(width: tapSide, height: tapSide).contentShape(Circle()).glassCircle().accessibilityLabel("AirPlay")
            Spacer()
            GlassIconButton(systemImage: activeModal == .queue ? "list.bullet.rectangle.portrait.fill" : "list.bullet",
                            tint: activeModal == .queue ? AG.amber : AG.inkMuted, accessibilityLabel: "Очередь") { openModal(.queue) }
        }
        .padding(.horizontal, 28).frame(minHeight: tapSide)
    }
    private var audioQualitySheetContent: some View {
        List {
            Section {
                ForEach(AudioQuality.allCases) { q in
                    Button { Haptics.tap(.medium); player.selectQuality(q); activeModal = nil } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(q.label).font(AG.text(.subheadline, .semibold)).foregroundStyle(AG.ink)
                                Text(q.detail).font(AG.text(.caption)).foregroundStyle(AG.inkMuted)
                            }
                            Spacer()
                            if player.audioQuality == q {
                                Image(systemName: "checkmark").font(AG.text(.subheadline, .bold)).foregroundStyle(AG.amber)
                            }
                        }
                        .padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
                    }
                }
            } header: { Text("Качество звука и кодеки") }
            footer: { Text("Для треков из Яндекс Музыки стриминг во FLAC Lossless активируется автоматически при стабильном интернет-соединении.") }
        }
        .navigationTitle("Качество звука").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { activeModal = nil }.foregroundStyle(AG.amber) } }
    }
    private var artistSelectionSheetContent: some View {
        List {
            Section("Выберите исполнителя") {
                ForEach(artistChoices) { artist in
                    Button { activeModal = nil; selectedArtist = artist } label: {
                        HStack {
                            Text(artist.name).font(AG.text(.callout, .medium)).foregroundStyle(AG.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(AG.text(.footnote, .semibold)).foregroundStyle(AG.inkFaint)
                        }
                        .padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
                    }
                }
            }
        }
        .navigationTitle("Исполнители").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { activeModal = nil }.foregroundStyle(AG.amber) } }
    }
    private func openModal(_ modal: ActivePlayerModal) {
        Haptics.tap(.light)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { activeModal = modal }
    }
    private func startTrackWave() {
        guard let current = track else { return }
        Haptics.tap(.medium); waveLoading = true
        Task {
            let waveTracks = await YandexMusicService.shared.buildTrackWave(from: current, target: 45)
            waveLoading = false
            guard player.currentTrack?.id == current.id else { return }
            if !waveTracks.isEmpty {
                // Retain the current occurrence so the coordinator can locate its successor.
                player.queue = player.isV2Enabled ? [current] + waveTracks.filter { $0.id != current.id } : waveTracks
                waveActive = true
                Haptics.success()
                withAnimation(AG.spring) { waveMessage = "🌊 Моя волна по треку запущена" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { waveMessage = nil } }
            }
        }
    }
    private func loadLyrics() async {
        lyrics = nil
        guard let requestedTrack = track else { lyricsLoading = false; return }
        lyricsLoading = true
        let result = try? await LyricsService.shared.fetchLyrics(for: requestedTrack)
        guard !Task.isCancelled, player.currentTrack?.id == requestedTrack.id else { return }
        lyrics = result
        lyricsLoading = false
    }
    private func togglePlayback() {
        Haptics.tap(.medium)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.togglePlay()
    }
    private func previousTrack() {
        Haptics.tap(.light)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.previous()
    }
    private func nextTrack() {
        Haptics.tap(.light)
        PlaybackAudioSessionCoordinator.shared.activateForPlayback()
        player.next()
    }
    private func openArtist() {
        guard let track else { return }
        resolvingArtist = true
        Task {
            let resolved = await YandexMusicService.shared.resolvePlayerArtists(for: track)
            resolvingArtist = false
            guard player.currentTrack?.id == track.id else { return }
            artistChoices = resolved
            if resolved.count == 1 { selectedArtist = resolved[0] }
            else if resolved.count > 1 { openModal(.artistSelection) }
        }
    }
    private func close() { Haptics.tap(.light); isPresented = false }
    private func toggleVideoShot() {
        Haptics.tap(.medium)
        withAnimation(.easeInOut(duration: 0.30)) {
            isVideoShotEnabled.toggle()
            UserDefaults.standard.set(isVideoShotEnabled, forKey: "aurora_videoshot_enabled")
            if isVideoShotEnabled, let url = videoShotURL { setupVideoLooper(url: url) }
            else { teardownVideoLooper() }
        }
    }
    private func loadVideoShot() async {
        guard let track else { videoShotURL = nil; teardownVideoLooper(); return }
        let ymId = PlayerCore.yandexTrackID(from: track)
        guard !ymId.isEmpty else { videoShotURL = nil; teardownVideoLooper(); return }
        let shotURL = await YandexMusicService.shared.getVideoShotUrl(for: ymId)
        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        if let shotURL {
            videoShotURL = shotURL
            if isVideoShotEnabled { setupVideoLooper(url: shotURL) }
        } else { videoShotURL = nil; teardownVideoLooper() }
    }
    private func setupVideoLooper(url: URL) {
        teardownVideoLooper()
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer(playerItem: item)
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none
        videoLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        videoLooperPlayer = queuePlayer
        if player.isPlaying { queuePlayer.play() }
    }
    private func teardownVideoLooper() { videoLooperPlayer?.pause(); videoLooperPlayer = nil; videoLooper = nil }
}

struct PlayerTimelineSection<Center: View>: View {
    @State private var player = ActivePlayerPresentation()
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var lastFeedbackProgress: Double = 0.0
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let center: Center
    init(@ViewBuilder center: () -> Center) { self.center = center() }
    private var effectiveProgress: Double { isScrubbing ? scrubProgress : player.progress }
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let maxDuration = max(player.duration, 0.01)
                let currentFraction = min(1.0, max(0.0, effectiveProgress / maxDuration))
                let activeWidth = max(0, min(geo.size.width, geo.size.width * currentFraction))
                let barHeight: CGFloat = isScrubbing ? 10 : 4
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.20)).frame(height: barHeight)
                    Capsule().fill(Color.white).frame(width: max(barHeight, activeWidth), height: barHeight)
                    if isScrubbing {
                        Circle().fill(Color.white).frame(width: 22, height: 22)
                            .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
                            .offset(x: activeWidth - 11).transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        if !isScrubbing { isScrubbing = true; selectionFeedback.prepare(); Haptics.tap(.soft) }
                        let fraction = min(1.0, max(0.0, val.location.x / max(geo.size.width, 1)))
                        scrubProgress = fraction * maxDuration
                        if abs(fraction - lastFeedbackProgress) > 0.04 {
                            Haptics.scrubTick(selectionFeedback); lastFeedbackProgress = fraction
                        }
                    }
                    .onEnded { val in
                        let fraction = min(1.0, max(0.0, val.location.x / max(geo.size.width, 1)))
                        player.seek(to: fraction * maxDuration)
                        withAnimation(AG.spring) { isScrubbing = false }
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Перемотка")
                .accessibilityValue(player.formatted(effectiveProgress))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: player.seek(to: min(player.duration, effectiveProgress + 10))
                    case .decrement: player.seek(to: max(0, effectiveProgress - 10))
                    @unknown default: break
                    }
                }
            }
            .frame(height: 24).animation(AG.fastSpring, value: isScrubbing)
            HStack(alignment: .center) {
                Text(player.formatted(effectiveProgress)).font(AG.text(.caption, .semibold).monospacedDigit())
                    .foregroundStyle(isScrubbing ? AG.ink : AG.inkMuted)
                Spacer()
                center
                Spacer()
                Text("-" + player.formatted(max(0, player.duration - effectiveProgress)))
                    .font(AG.text(.caption, .semibold).monospacedDigit()).foregroundStyle(isScrubbing ? AG.ink : AG.inkMuted)
            }
            .animation(.easeInOut(duration: 0.2), value: isScrubbing)
        }
        .task { await player.observeTimeline() }
        .onChange(of: player.currentTrack?.id) { _, _ in isScrubbing = false }
    }
}

struct AutoMixBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let title = "AutoMix"
    private let sweepCycle: TimeInterval = 2.6
    var body: some View {
        Group {
            if reduceMotion { fullMark(sweep: nil) }
            else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let phase = time.truncatingRemainder(dividingBy: sweepCycle) / sweepCycle
                    fullMark(sweep: CGFloat(phase))
                }
            }
        }
        .accessibilityLabel(Text(title)).allowsHitTesting(false)
    }
    @ViewBuilder private func fullMark(sweep: CGFloat?) -> some View {
        let usingGemini = GeminiAutoMixPlanner.lastPlanUsedGemini
        HStack(spacing: 4) {
            mark(sweep: sweep)
            Text(usingGemini ? "AI" : "DSP").font(AG.text(.caption2, .bold))
                .foregroundStyle(usingGemini ? AG.positive : AG.inkFaint).fixedSize()
                .accessibilityLabel(Text(usingGemini ? "План Gemini AI" : "Локальный DSP-движок"))
        }
    }
    private func mark(sweep: CGFloat?) -> some View {
        let label = Text(title).font(AG.text(.caption, .semibold))
        return label.foregroundStyle(.white.opacity(0.78)).overlay {
            if let sweep {
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let band = max(width * 0.5, 22)
                    let travel = width + band * 2
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .white, .white.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: band).offset(x: -band + sweep * travel)
                        .frame(width: width, height: geo.size.height, alignment: .leading).clipped().blendMode(.plusLighter)
                }
                .mask(label).allowsHitTesting(false)
            }
        }
        .shadow(color: .white.opacity(0.45), radius: 5).shadow(color: .white.opacity(0.18), radius: 11)
        .fixedSize().compositingGroup()
    }
}

struct NativeVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.85)
                slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
            }
        }
        return volumeView
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
struct VideoShotPlayerView: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView(); view.player = player; return view
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) { uiView.player = player }
    class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVPlayer? {
            get { playerLayer.player }
            set { playerLayer.player = newValue; playerLayer.videoGravity = .resizeAspectFill }
        }
    }
}

#Preview("Full player") { PlayerScreenV2(isPresented: .constant(true)) }
#Preview("Timeline") { PlayerTimelineSection { Text(verbatim: "AutoMix V2") }.padding() }
