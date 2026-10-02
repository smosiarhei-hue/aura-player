import SwiftUI

// MARK: - Экран Радио (Apple Music 2026 Style — Экран 7)

struct RadioStationsExploreView: View {
    @State private var ym = YandexMusicService.shared
    @State private var presentation = ActivePlayerPresentation.shared

    private let stations = YandexMusicService.rotorStations

    var body: some View {
        NavigationStack {
            ZStack {
                SN.bg.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        // Заголовок
                        Text("Радио")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(SN.ink)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)

                        // Hero-блок с красным светящимся радио
                        heroRadioCard

                        // Секция станций
                        stationsSection
                    }
                    .padding(.bottom, 130)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Hero Card

    private var heroRadioCard: some View {
        VStack(spacing: 16) {
            // Светящаяся радио-иконка
            ZStack {
                Circle()
                    .fill(Color(hex: "#FF2D55")?.opacity(0.18) ?? Color.pink.opacity(0.18))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)

                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Color(hex: "#FF2D55") ?? .pink)
            }
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Радио")
                    .font(SN.display(.title2, .bold))
                    .foregroundStyle(SN.ink)

                Text("Музыка без границ. Новые открытия каждый день.")
                    .font(SN.text(.subheadline, .medium))
                    .foregroundStyle(SN.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Кнопка "Слушать сейчас"
            Button {
                Haptics.tap(.heavy)
                startPersonalWave()
            } label: {
                Text("Слушать сейчас")
                    .font(SN.text(.subheadline, .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 32)
                    .frame(height: 46)
                    .background(Color.white, in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.95))
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Stations Section

    private var stationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Станции")
                .font(SN.display(.title3, .bold))
                .foregroundStyle(SN.ink)
                .padding(.horizontal, 20)

            LazyVStack(spacing: 8) {
                ForEach(stations) { station in
                    Button {
                        playStation(station)
                    } label: {
                        HStack(spacing: 14) {
                            // Градиентная иконка станции
                            ZStack {
                                LinearGradient(
                                    colors: stationColors(for: station),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: station.icon)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.30), radius: 6, y: 3)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.title)
                                    .font(SN.text(.body, .semibold))
                                    .foregroundStyle(SN.ink)
                                    .lineLimit(1)

                                Text(station.subtitle)
                                    .font(SN.text(.caption, .regular))
                                    .foregroundStyle(SN.inkMuted)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SN.inkMuted.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func stationColors(for station: YandexMusicService.StationOption) -> [Color] {
        station.gradient.compactMap { Color(hex: $0) }
    }

    private func startPersonalWave() {
        if let waveStation = stations.first(where: { $0.id == "wave" }) {
            playStation(waveStation)
        }
    }

    private func playStation(_ station: YandexMusicService.StationOption) {
        Haptics.tap(.medium)
        SonivoPlay.wave(station, forceFresh: true)
    }
}
