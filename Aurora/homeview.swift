import SwiftUI

// MARK: - Tab 1: Главная

struct HomeView: View {
    @State private var player = PlayerCore.shared
    @State private var ym = YandexMusicService.shared

    @State private var chart: [YandexMusicService.YMTrackItem] = []
    @State private var albums: [YandexMusicService.YMAlbumItem] = []
    @State private var isLoading = false
    @State private var showSettings = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 5 { return "Доброй ночи" }
        if h < 12 { return "Доброе утро" }
        if h < 18 { return "Добрый день" }
        return "Добрый вечер"
    }

    private var topFive: [RankedTrack] {
        chart.prefix(5).enumerated().map { RankedTrack(rank: $0.offset + 1, item: $0.element) }
    }

    private var moodStation: YandexMusicService.StationOption { ym.waveMoodStation }
    private var moodColors: [Color] { moodStation.gradient.compactMap { Color(hex: $0) } }

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        heroHeader.riseIn()
                        waveHero.riseIn(delay: 0.05)
                        stationsRow.riseIn(delay: 0.10)
                        chartSection.riseIn(delay: 0.15)
                        albumsSection.riseIn(delay: 0.20)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 84)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(AG.ink)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await load() }
        }
    }

    // MARK: Header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting.uppercased())
                .font(AG.text(10, .heavy))
                .tracking(1.8)
                .foregroundStyle(AG.amber)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Слушайте")
                    .font(AG.display(30, .heavy))
                    .foregroundStyle(AG.ink)
                Text("своё")
                    .font(AG.serifAccent(30))
                    .foregroundStyle(AG.amber)
            }

            Text("Без навязанных повторов и лишнего шума")
                .font(AG.text(12.5, .regular))
                .foregroundStyle(AG.inkMuted)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Волна под настроение (MyWaveWidget)

    private var waveHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                SonivoPlay.wave(moodStation)
            } label: {
                ZStack(alignment: .leading) {
                    // 1. Фоновый градиент карточки
                    LinearGradient(
                        colors: moodColors.isEmpty ? [Color(hex: "E58C12") ?? .orange, Color(hex: "F26101") ?? .red] : moodColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    // 2. Слой процедурной волны (смещен вправо, без жесткой обрезки)
                    GeometryReader { geo in
                        FluidWaveView(
                            colors: moodColors,
                            isBackgroundMode: false
                        )
                        .frame(width: geo.size.height * 1.35, height: geo.size.height * 1.35)
                        .position(x: geo.size.width * 0.78, y: geo.size.height * 0.50)
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)

                    // 3. Информационный оверлей (Текст слева)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ПОД НАСТРОЕНИЕ")
                            .font(.system(size: 11.5, weight: .heavy))
                            .tracking(1.4)
                            .foregroundStyle(Color.black.opacity(0.62))

                        Spacer()

                        Text(moodStation.title)
                            .font(AG.display(28, .heavy))
                            .foregroundStyle(Color.black.opacity(0.92))

                        Text(moodStation.stationId == "user:onyourwave" ? ym.waveSubtitle : moodStation.subtitle)
                            .font(AG.text(12.5, .medium))
                            .foregroundStyle(Color.black.opacity(0.72))
                            .lineLimit(2)
                            .padding(.top, 4)
                    }
                    .padding(20)

                    // 4. Кнопка Play в правом верхнем углу (строго над анимацией)
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.85))
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(16)
                    .zIndex(2)
                }
                .frame(height: 185)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .padding(.horizontal, 16)
            }
            .buttonStyle(GlassPressStyle())

            // «Рулетка» настроений — Liquid Glass / Chrome карусель по дуге:
            // волна перестраивается и запускается мгновенно, когда колесо
            // остановится на настроении.
            MoodRouletteView(
                stations: YandexMusicService.rotorStations,
                selectedStationId: $ym.waveMoodStationId
            ) { station in
                SonivoPlay.wave(station)
            }
        }
    }

    // MARK: Станции

    private var stationsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Волны", accent: "по настроению")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(YandexMusicService.rotorStations.dropFirst()) { station in
                        Button {
                            SonivoPlay.wave(station)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(
                                        colors: station.gradient.compactMap { Color(hex: $0) },
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    Image(systemName: station.icon)
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(Color.black.opacity(0.72))
                                }
                                .frame(width: 132, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(AG.hairline, lineWidth: 0.8)
                                )

                                Text(station.title)
                                    .font(AG.text(13, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(station.subtitle)
                                    .font(AG.text(10.5, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Чарт — 5 треков + все

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                SonivoHeader(title: "Чарт", accent: "сегодня")

                Spacer(minLength: 8)

                NavigationLink {
                    Top100ChartView(title: "Чарт", tracks: chart)
                } label: {
                    SonivoMoreButton(title: "Все")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if isLoading && chart.isEmpty {
                ProgressView()
                    .tint(AG.amber)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(topFive) { row in
                        ChartRowView(rank: row.rank, item: row.item) {
                            SonivoPlay.track(row.item, in: chart)
                        }
                    }
                }

                NavigationLink {
                    Top100ChartView(title: "Топ 100", tracks: chart)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Смотреть все · Топ 100")
                            .font(AG.text(13, .bold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .black))
                    }
                    .foregroundStyle(AG.amber)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(AG.hairline, lineWidth: 0.8)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .buttonStyle(GlassPressStyle())
            }
        }
    }

    // MARK: Свежие релизы

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SonivoHeader(title: "Свежие", accent: "релизы")
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(albums.prefix(12)) { album in
                        NavigationLink {
                            AlbumView(albumId: String(album.id), title: album.displayTitle)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                RemoteArtwork(urlString: album.coverUrlString, corner: 16)
                                    .frame(width: 142, height: 142)

                                Text(album.displayTitle)
                                    .font(AG.text(13, .semibold))
                                    .foregroundStyle(AG.ink)
                                    .lineLimit(1)

                                Text(album.artistName)
                                    .font(AG.text(10.5, .regular))
                                    .foregroundStyle(AG.inkMuted)
                                    .lineLimit(1)
                            }
                            .frame(width: 142, alignment: .leading)
                        }
                        .buttonStyle(GlassPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        isLoading = true
        chart = (try? await ym.getChart()) ?? []
        isLoading = false
        albums = (try? await ym.getNewAlbums()) ?? []
    }
}
