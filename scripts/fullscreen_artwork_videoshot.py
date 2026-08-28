from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THEME = ROOT / "Aurora" / "theme.swift"
SETTINGS = ROOT / "Aurora" / "settingsview.swift"
MODELS = ROOT / "Aurora" / "models.swift"
YANDEX = ROOT / "Aurora" / "yandexmusicservice.swift"
SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"


def replace_required(text, old, new, label):
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"{label}: required source anchor was not found")
    return text.replace(old, new, 1)


theme = THEME.read_text(encoding="utf-8")
theme = replace_required(theme,
'''    var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }

    // Karaoke lyrics''',
'''    var scrubHapticsEnabled: Bool { didSet { defaults.set(scrubHapticsEnabled, forKey: "settings.scrubHaptics") } }
    var fullScreenArtworkEnabled: Bool { didSet { defaults.set(fullScreenArtworkEnabled, forKey: "player.fullScreenArtwork") } }
    var videoShotsEnabled: Bool { didSet { defaults.set(videoShotsEnabled, forKey: "player.videoShots") } }

    // Karaoke lyrics''', "artwork settings")
theme = replace_required(theme,
'''        scrubHapticsEnabled = defaults.object(forKey: "settings.scrubHaptics") as? Bool ?? true
        lyricsFontSize''',
'''        scrubHapticsEnabled = defaults.object(forKey: "settings.scrubHaptics") as? Bool ?? true
        fullScreenArtworkEnabled = defaults.object(forKey: "player.fullScreenArtwork") as? Bool ?? true
        videoShotsEnabled = defaults.object(forKey: "player.videoShots") as? Bool ?? true
        lyricsFontSize''', "artwork defaults")
THEME.write_text(theme, encoding="utf-8")

settings = SETTINGS.read_text(encoding="utf-8")
settings = replace_required(settings,
'''                    HStack {
                        Text("Цветовой акцент")''',
'''                    Toggle("Обложка на весь экран", isOn: $settings.fullScreenArtworkEnabled)
                        .tint(settings.accentColor)
                    Toggle("Видеошоты Яндекс Музыки", isOn: $settings.videoShotsEnabled)
                        .tint(settings.accentColor)
                        .disabled(!settings.fullScreenArtworkEnabled)
                    Text("Если у трека есть видеошот, он заменит статичную полноэкранную обложку. Видео без звука и не влияет на музыку.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Цветовой акцент")''', "appearance toggles")
SETTINGS.write_text(settings, encoding="utf-8")

models = MODELS.read_text(encoding="utf-8")
models = replace_required(models,
'''    var coverURL: String? = nil
    var lyricsText: String? = nil''',
'''    var coverURL: String? = nil
    var videoShotURL: String? = nil
    var lyricsText: String? = nil''', "track video URL")
MODELS.write_text(models, encoding="utf-8")

yandex = YANDEX.read_text(encoding="utf-8")
yandex = replace_required(yandex,
'''        let coverUri: String?
        let artists: [YMArtist]?''',
'''        let coverUri: String?
        let backgroundVideoUri: String?
        let backgroundVideoId: String?
        let playerId: String?
        let artists: [YMArtist]?''', "Yandex video fields")
yandex = replace_required(yandex,
'''            case id, title, available, durationMs, coverUri, artists, albums''',
'''            case id, title, available, durationMs, coverUri, backgroundVideoUri, backgroundVideoId, playerId, artists, albums''', "Yandex video coding keys")
yandex = replace_required(yandex,
'''            coverUri = try? c.decode(String.self, forKey: .coverUri)
            artists = try? c.decode([YMArtist].self, forKey: .artists)''',
'''            coverUri = try? c.decode(String.self, forKey: .coverUri)
            backgroundVideoUri = try? c.decode(String.self, forKey: .backgroundVideoUri)
            backgroundVideoId = try? c.decode(String.self, forKey: .backgroundVideoId)
            playerId = try? c.decode(String.self, forKey: .playerId)
            artists = try? c.decode([YMArtist].self, forKey: .artists)''', "Yandex video decoding")
yandex = replace_required(yandex,
'''        var coverUrlString: String? {
            let raw = coverUri ?? albums?.first?.coverUri
            guard let uri = raw, !uri.isEmpty else { return nil }
            return "https://" + uri.replacingOccurrences(of: "%%", with: "400x400")
        }

        static func ==''',
'''        var coverUrlString: String? {
            let raw = coverUri ?? albums?.first?.coverUri
            guard let uri = raw, !uri.isEmpty else { return nil }
            return "https://" + uri.replacingOccurrences(of: "%%", with: "1000x1000")
        }

        var videoShotUrlString: String? {
            guard let raw = backgroundVideoUri?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return raw }
            return "https://" + raw
        }

        static func ==''', "Yandex video URL")
yandex = replace_required(yandex,
'''            coverURL: ym.coverUrlString
        )''',
'''            coverURL: ym.coverUrlString,
            videoShotURL: ym.videoShotUrlString
        )''', "track video conversion")
YANDEX.write_text(yandex, encoding="utf-8")

screen = SCREEN.read_text(encoding="utf-8")
screen = replace_required(screen,
'''    @State private var scrubPosition: Double = 0
''',
'''    @State private var scrubPosition: Double = 0
    @State private var scrubHapticEngine = ScrubHapticEngine()
''', "scrub haptic state")
screen = replace_required(screen,
'''                        animatedCover(side: coverSide)
                            .padding(.top, 18)''',
'''                        if settings.fullScreenArtworkEnabled {
                            Color.clear
                                .frame(height: max(geo.size.height * 0.38, coverSide * 0.82))
                                .padding(.top, 4)
                        } else {
                            animatedCover(side: coverSide)
                                .padding(.top, 18)
                        }''', "immersive player layout")
screen = replace_required(screen,
'''            AG.bg

            RadialGradient''',
'''            AG.bg

            if settings.fullScreenArtworkEnabled {
                fullScreenMediaBackground
                    .transition(.opacity)
            }

            RadialGradient''', "immersive artwork background")
screen = replace_required(screen,
'''            LinearGradient(colors: [.black.opacity(0.08), AG.bg.opacity(0.50), AG.bg.opacity(0.92)], startPoint: .top, endPoint: .bottom)''',
'''            LinearGradient(
                colors: settings.fullScreenArtworkEnabled
                    ? [.black.opacity(0.02), .black.opacity(0.12), .black.opacity(0.78), .black.opacity(0.98)]
                    : [.black.opacity(0.08), AG.bg.opacity(0.50), AG.bg.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )''', "immersive legibility gradient")
screen = replace_required(screen,
'''    // MARK: Header
''',
'''    @ViewBuilder private var fullScreenMediaBackground: some View {
        if settings.videoShotsEnabled,
           !reduceMotion,
           let value = track?.videoShotURL,
           let url = URL(string: value) {
            FullScreenArtworkVideo(url: url)
                .id(value)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else {
            artwork
                .scaledToFill()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    // MARK: Header
''', "immersive media view")
screen = replace_required(screen,
'''                Button { showSettings = true } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                Divider()''',
'''                Button {
                    withAnimation(.smooth(duration: 0.28)) {
                        settings.fullScreenArtworkEnabled.toggle()
                    }
                } label: {
                    Label(
                        settings.fullScreenArtworkEnabled ? "Отключить обложку на весь экран" : "Обложка на весь экран",
                        systemImage: settings.fullScreenArtworkEnabled ? "rectangle.slash" : "rectangle.inset.filled"
                    )
                }
                Button { showSettings = true } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                Divider()''', "player artwork toggle")
screen = replace_required(screen,
'''value: Binding(get: { isScrubbing ? scrubPosition : player.progress }, set: { scrubPosition = $0 }),''',
'''value: Binding(
                    get: { isScrubbing ? scrubPosition : player.progress },
                    set: { value in
                        scrubPosition = value
                        scrubHapticEngine.update(to: value, enabled: settings.scrubHapticsEnabled)
                    }
                ),''', "velocity scrub haptics")
screen = replace_required(screen,
'''                    if editing { scrubPosition = player.progress; isScrubbing = true }
                    else { let target = scrubPosition; isScrubbing = false; player.seek(to: target) }''',
'''                    if editing {
                        scrubPosition = player.progress
                        isScrubbing = true
                        scrubHapticEngine.begin(at: scrubPosition)
                    } else {
                        let target = scrubPosition
                        isScrubbing = false
                        scrubHapticEngine.end(enabled: settings.scrubHapticsEnabled)
                        player.seek(to: target)
                    }''', "scrub haptic lifecycle")
SCREEN.write_text(screen, encoding="utf-8")
print("Immersive artwork, velocity scrub haptics, and Yandex video shots applied.")
