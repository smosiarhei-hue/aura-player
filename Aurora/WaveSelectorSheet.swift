import SwiftUI

// MARK: - Wave Selector Sheet
//
// Полноэкранный выбор волны, поднимающийся снизу с главной карточки
// «Моя волна». Заменяет прежнюю постоянную рулетку иконок на главном
// экране: полный список настроений теперь живёт только здесь, в виде
// органичных цветных «капель» с иконкой и подписью — по образцу
// эталонного макета («Время помечтать», «В дорогу», «Распаковать итоги
// лета» и т.д.).

struct WaveSelectorSheet: View {
    let stations: [YandexMusicService.StationOption]
    @Binding var selectedStationId: String
    var onSelect: (YandexMusicService.StationOption) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 148, maximum: 180), spacing: 14)],
                        spacing: 14
                    ) {
                        ForEach(stations) { station in
                            WaveBlobCard(
                                station: station,
                                isSelected: station.stationId == selectedStationId
                            ) {
                                choose(station)
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Выбор волны")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .font(AG.text(14, .bold))
                        .foregroundStyle(AG.amber)
                }
            }
        }
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    private func choose(_ station: YandexMusicService.StationOption) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selectedStationId = station.stationId
        onSelect(station)
        dismiss()
    }
}

// MARK: - Blob card

private struct WaveBlobCard: View {
    let station: YandexMusicService.StationOption
    let isSelected: Bool
    let action: () -> Void

    private var colors: [Color] {
        let cs = station.gradient.compactMap { Color(hex: $0) }
        return cs.isEmpty ? [AG.amber, AG.ember] : cs
    }

    private var isRecap: Bool { station.stationId == "app:recap" }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                BlobShape()
                    .fill(
                        RadialGradient(colors: colors, center: .topLeading, startRadius: 6, endRadius: 210)
                    )
                    .overlay(
                        BlobShape()
                            .stroke(
                                isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.16),
                                lineWidth: isSelected ? 2.6 : 0.9
                            )
                    )
                    .shadow(color: (colors.first ?? AG.amber).opacity(0.35), radius: 14, y: 8)

                Image(systemName: station.icon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.30))
                    .padding(.leading, 18)
                    .padding(.top, 18)

                VStack {
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(station.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.88))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if isRecap {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.black.opacity(0.62))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .padding(.bottom, 20)
                }
            }
            .frame(height: 168)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassPressStyle())
    }
}

/// Органичная асимметричная «капля» по образцу референса — не идеальный
/// овал, а слегка скошенная форма с более узкой нижней «ножкой».
private struct BlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.52, y: 0))
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.40),
            control1: CGPoint(x: w * 0.86, y: 0),
            control2: CGPoint(x: w, y: h * 0.13)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.60, y: h),
            control1: CGPoint(x: w, y: h * 0.78),
            control2: CGPoint(x: w * 0.88, y: h)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.06, y: h * 0.60),
            control1: CGPoint(x: w * 0.26, y: h),
            control2: CGPoint(x: 0, y: h * 0.86)
        )
        path.addCurve(
            to: CGPoint(x: w * 0.52, y: 0),
            control1: CGPoint(x: 0, y: h * 0.26),
            control2: CGPoint(x: w * 0.18, y: 0)
        )
        path.closeSubpath()
        return path
    }
}
