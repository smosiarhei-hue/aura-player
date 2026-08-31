from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"
PLAYER = ROOT / "Aurora" / "playercore.swift"
YANDEX = ROOT / "Aurora" / "yandexmusicservice.swift"


def replace_required(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


def replace_section(text: str, start: str, end: str, replacement: str, label: str) -> str:
    if replacement in text:
        return text
    start_index = text.find(start)
    end_index = text.find(end, start_index + len(start))
    if start_index < 0 or end_index < 0:
        raise RuntimeError(f"{label}: section markers were not found")
    return text[:start_index] + replacement + text[end_index:]


screen = SCREEN.read_text(encoding="utf-8")
screen = replace_required(
    screen,
    '''    @State private var previewLyrics: Lyrics?
    @State private var lyricsLoading = false
''',
    '''    @State private var previewLyrics: Lyrics?
    @State private var lyricsLoading = false
    @State private var resolvedCoverURL: String?
    @State private var resolvedVideoShotURL: String?
''',
    "visual media state",
)
screen = replace_required(
    screen,
    '''        .task(id: track?.id) {
            await loadLyricsPreview()
        }
''',
    '''        .task(id: track?.id) {
            await loadLyricsPreview()
        }
        .task(id: track?.id) {
            await loadVisualMedia()
        }
''',
    "visual media task",
)
screen = replace_required(
    screen,
    '''                        featureDock
                            .padding(.top, 18)

                        transitionCard
                            .padding(.top, 12)

                        trackWaveCard
                            .padding(.top, 10)
''',
    '''                        transitionCard
                            .padding(.top, 18)

                        trackWaveCard
                            .padding(.top, 10)

                        featureDock
                            .padding(.top, 18)
''',
    "bottom settings placement",
)

background_section = '''    // MARK: Background

    private var background: some View {
        ZStack {
            AG.bg
            if settings.fullScreenArtworkEnabled {
                fullScreenMediaBackground
            } else {
                let colors = palette.isEmpty ? [AG.amber, AG.ember, Color.black] : palette
                RadialGradient(
                    colors: [colors[0].opacity(0.42), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 430
                )
                RadialGradient(
                    colors: [colors[min(1, colors.count - 1)].opacity(0.30), .clear],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 460
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder private var fullScreenMediaBackground: some View {
        GeometryReader { mediaGeo in
            Group {
                if settings.videoShotsEnabled,
                   !reduceMotion,
                   let value = resolvedVideoShotURL ?? track?.videoShotURL,
                   let url = URL(string: value) {
                    FullScreenArtworkVideo(url: url)
                        .id(value)
                } else if let value = resolvedCoverURL ?? track?.coverURL,
                          let url = URL(string: value) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            fallbackArtwork
                        }
                    }
                } else {
                    artwork
                }
            }
            .frame(width: mediaGeo.size.width, height: mediaGeo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

'''
screen = replace_section(
    screen,
    "    // MARK: Background\n",
    "    // MARK: Header\n",
    background_section,
    "undimmed player background",
)

lyrics_section = '''    // MARK: Stable inline lyrics

    private var inlineLyrics: some View {
        Button { showLyrics = true } label: {
            Group {
                if lyricsLoading {
                    Text("Загрузка текста…")
                        .foregroundStyle(.white.opacity(0.72))
                } else if let lines = activeLyricsLines {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lines.current)
                            .font(.system(size: 25, weight: .bold, design: .default))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.78)
                            .fixedSize(horizontal: false, vertical: true)
                        if let next = lines.next {
                            Text(next)
                                .font(.system(size: 17, weight: .semibold, design: .default))
                                .foregroundStyle(.white.opacity(0.64))
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                        }
                    }
                } else if let fallback = track?.lyricsText, !fallback.isEmpty {
                    Text(fallback)
                        .font(.system(size: 22, weight: .bold, design: .default))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .minimumScaleFactor(0.76)
                } else {
                    Text("Текст песни не найден")
                        .font(.system(size: 18, weight: .semibold, design: .default))
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.72), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(track == nil)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityHint("Открывает полный текст песни")
    }

    private var activeLyricsLines: (current: String, next: String?)? {
        guard let previewLyrics, !previewLyrics.lines.isEmpty else { return nil }
        if !previewLyrics.isSynchronized {
            return (previewLyrics.lines[0].text, previewLyrics.lines.dropFirst().first?.text)
        }

        let time = player.progress + settings.lyricsOffset
        let index = previewLyrics.lines.lastIndex(where: { $0.startTime <= time }) ?? 0
        let nextIndex = index + 1
        let next = nextIndex < previewLyrics.lines.count ? previewLyrics.lines[nextIndex].text : nil
        return (previewLyrics.lines[index].text, next)
    }

    private func loadLyricsPreview() async {
        previewLyrics = nil
        guard let requestedTrack = track else {
            lyricsLoading = false
            return
        }

        lyricsLoading = true
        let result = try? await LyricsService.shared.fetchLyrics(for: requestedTrack)
        guard player.currentTrack?.id == requestedTrack.id else { return }
        previewLyrics = result
        lyricsLoading = false
    }

    private func loadVisualMedia() async {
        resolvedCoverURL = nil
        resolvedVideoShotURL = nil
        guard let requestedTrack = track, requestedTrack.isStream else { return }
        let media = await YandexMusicService.shared.loadVisualMedia(for: requestedTrack)
        guard player.currentTrack?.id == requestedTrack.id else { return }
        resolvedCoverURL = media.coverURL
        resolvedVideoShotURL = media.videoShotURL
    }

'''
screen = replace_section(
    screen,
    "    // MARK: Inline karaoke\n",
    "    // MARK: Playback controls\n",
    lyrics_section,
    "plain stable lyrics",
)

settings_section = '''    // MARK: Bottom settings

    private var featureDock: some View {
        HStack {
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(.ultraThinMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки")
        }
    }

'''
screen = replace_section(
    screen,
    "    // MARK: Feature controls\n",
    "    private var transitionCard: some View {",
    settings_section,
    "simple settings control",
)

screen = replace_required(
    screen,
    '''                    .foregroundStyle(.white.opacity(0.78))
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())''',
    '''                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())''',
    "artist tap target",
)
SCREEN.write_text(screen, encoding="utf-8")

player = PLAYER.read_text(encoding="utf-8")
player = replace_required(
    player,
    "let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)",
    "let interval = CMTime(seconds: 0.10, preferredTimescale: 600)",
    "stream progress refresh rate",
)
player = replace_required(
    player,
    "let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true)",
    "let timer = Timer(timeInterval: 0.10, repeats: true)",
    "local progress refresh rate",
)
player = replace_required(
    player,
    '''        sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerRemaining = Double(minutes) * 60
        sleepTimerMinutes = minutes
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSleepTimer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }

    private func tickSleepTimer() {
        guard let deadline = sleepDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            pause()
            cancelSleepTimer()
        } else {
            sleepTimerRemaining = remaining
        }
    }''',
    '''        let delay = Double(minutes) * 60
        sleepDeadline = Date().addingTimeInterval(delay)
        sleepTimerRemaining = delay
        sleepTimerMinutes = minutes
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pause()
                self.cancelSleepTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sleepTimer = timer
    }''',
    "one-shot sleep timer",
)
PLAYER.write_text(player, encoding="utf-8")

yandex = YANDEX.read_text(encoding="utf-8")
yandex = replace_required(
    yandex,
    '''        var videoShotUrlString: String? {
            guard let raw = backgroundVideoUri?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return raw }
            return "https://" + raw
        }''',
    '''        var videoShotUrlString: String? {
            guard let raw = backgroundVideoUri?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            let normalized = raw.replacingOccurrences(of: "%%", with: "1000x1345")
            if normalized.hasPrefix("https://") || normalized.hasPrefix("http://") { return normalized }
            if normalized.hasPrefix("//") { return "https:" + normalized }
            return "https://" + normalized
        }''',
    "video shot URL normalization",
)
yandex = replace_required(
    yandex,
    '''    // MARK: - Helpers
''',
    '''    func loadVisualMedia(for track: Track) async -> (coverURL: String?, videoShotURL: String?) {
        guard let trackId = Self.ymId(fromFileName: track.fileName) else {
            return (track.coverURL, track.videoShotURL)
        }
        var components = URLComponents(string: Self.apiBase + "/tracks")!
        components.queryItems = [URLQueryItem(name: "track-ids", value: trackId)]
        guard let url = components.url,
              let pair = try? await URLSession.shared.data(for: authorizedRequest(url: url)) else {
            return (track.coverURL, track.videoShotURL)
        }
        struct Response: Decodable { let result: [YMTrackItem]? }
        guard let item = (try? JSONDecoder().decode(Response.self, from: pair.0))?.result?.first else {
            return (track.coverURL, track.videoShotURL)
        }
        return (item.coverUrlString ?? track.coverURL, item.videoShotUrlString ?? track.videoShotURL)
    }

    // MARK: - Helpers
''',
    "full track visual enrichment",
)
YANDEX.write_text(yandex, encoding="utf-8")

print("iOS 26 player UI cleanup, visual media enrichment, and performance optimization applied.")
