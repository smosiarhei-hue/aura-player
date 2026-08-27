from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER_SCREEN = ROOT / "Aurora" / "PlayerScreenV2.swift"
text = PLAYER_SCREEN.read_text()

state_anchor = '''    @State private var dismissing = false
'''
state_block = '''    @State private var dismissing = false
    @State private var buildingTrackWave = false
    @State private var trackWaveReady = false
    @State private var trackWaveMessage: String?
'''
if state_block not in text:
    if state_anchor not in text:
        raise RuntimeError("Player state anchor was not found")
    text = text.replace(state_anchor, state_block, 1)

scroll_open_old = '''                VStack(spacing: 0) {
                    topBar'''
scroll_open_new = '''                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                    topBar'''
if scroll_open_new not in text:
    if scroll_open_old not in text:
        raise RuntimeError("Player content stack was not found")
    text = text.replace(scroll_open_old, scroll_open_new, 1)

scroll_close_old = '''                .padding(.bottom, max(10, geo.safeAreaInsets.bottom))
            }
            .offset'''
scroll_close_new = '''                .padding(.bottom, max(10, geo.safeAreaInsets.bottom))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .offset'''
if scroll_close_new not in text:
    if scroll_close_old not in text:
        raise RuntimeError("Player scroll closing anchor was not found")
    text = text.replace(scroll_close_old, scroll_close_new, 1)

old_tools = '''    private var bottomTools: some View {
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
'''
new_tools = '''    private var bottomTools: some View {
        VStack(spacing: 10) {
            Button(action: startTrackWave) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.13))
                            .frame(width: 42, height: 42)
                        if buildingTrackWave {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(trackWaveReady ? "Волна по песне включена" : "Включить волну по этой песне")
                            .font(AG.text(14, .bold))
                            .foregroundStyle(.white)
                        Text(trackWaveMessage ?? "Похожие треки без повторов — продолжатся после текущего")
                            .font(AG.text(10.5, .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: trackWaveReady ? "checkmark.circle.fill" : "chevron.right")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.8)
                }
            }
            .buttonStyle(.plain)
            .disabled(track == nil || buildingTrackWave)

            HStack {
                Image(systemName: "quote.bubble")
                Spacer()
                AirPlayButtonView().frame(width: 44, height: 44)
                Spacer()
                Image(systemName: "list.bullet")
            }
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white.opacity(0.82))
            .frame(height: 44)
            .padding(.horizontal, 18)
        }
    }
'''
if new_tools not in text:
    if old_tools not in text:
        raise RuntimeError("Player bottom tools block was not found")
    text = text.replace(old_tools, new_tools, 1)

function_anchor = '''    private func togglePlayback() {
'''
wave_function = '''    private func startTrackWave() {
        guard let seed = track, !buildingTrackWave else { return }
        buildingTrackWave = true
        trackWaveReady = false
        trackWaveMessage = "Подбираем точное продолжение…"

        Task {
            let related = await YandexMusicService.shared.buildTrackWave(from: seed)
            guard player.currentTrack?.id == seed.id else {
                buildingTrackWave = false
                trackWaveMessage = nil
                return
            }

            guard !related.isEmpty else {
                buildingTrackWave = false
                trackWaveMessage = "Не удалось найти достаточно похожих песен"
                return
            }

            var seen = Set<UUID>([seed.id])
            let unique = related.filter { seen.insert($0.id).inserted }
            player.queue = [seed] + unique

            if let ymID = YandexMusicService.ymId(fromFileName: seed.fileName) {
                YandexMusicService.shared.beginStationSession("track:\\(ymID)")
            }

            trackWaveReady = true
            buildingTrackWave = false
            trackWaveMessage = "В очереди: \\(unique.count) похожих треков"
        }
    }

    private func togglePlayback() {
'''
if wave_function not in text:
    if function_anchor not in text:
        raise RuntimeError("Player action anchor was not found")
    text = text.replace(function_anchor, wave_function, 1)

sheet_old = '''        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistView(artistId: artist.id) }
                .preferredColorScheme(.dark)
        }
'''
sheet_new = '''        .sheet(item: $selectedArtist) { artist in
            NavigationStack { ArtistView(artistId: artist.id) }
                .preferredColorScheme(.dark)
        }
        .onChange(of: track?.id) { _, _ in
            buildingTrackWave = false
            trackWaveReady = false
            trackWaveMessage = nil
        }
'''
if sheet_new not in text:
    if sheet_old not in text:
        raise RuntimeError("Player sheet anchor was not found")
    text = text.replace(sheet_old, sheet_new, 1)

PLAYER_SCREEN.write_text(text)
