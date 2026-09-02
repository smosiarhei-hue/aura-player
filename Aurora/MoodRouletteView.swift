import SwiftUI

// MARK: - Mood Roulette ("Liquid Glass / Chrome" arc carousel)
//
// Интерактивный селектор настроений в стиле "рулетки" по макету:
// горизонтальная карусель с эффектом выпуклой дуги (боковые ячейки
// уменьшаются, опускаются вниз и тускнеют), магнитной центровкой
// (`.scrollTargetBehavior(.viewAligned)`), хаптик-тиком на смену центральной
// ячейки (троттлинг 45мс) и фоновой волной "жидкого хрома" под капсулами.
//
// Готовые запечённые PNG-иконки (машина / облако-капля / бабочка и т.д.)
// подставляются через `StationOption.icon` (сейчас SF Symbol как заглушка —
// в проекте достаточно положить `moodIcon_<id>` в assets.xcassets и
// переключить `MoodCapsuleCell` на `Image("moodIcon_" + station.id)`).

struct MoodRouletteView: View {
    let stations: [YandexMusicService.StationOption]
    @Binding var selectedStationId: String
    var onSelect: (YandexMusicService.StationOption) -> Void

    private let cellSize: CGFloat = 62
    private let cellSpacing: CGFloat = 16
    private let space = "moodRouletteSpace"

    @State private var cellOffsets: [String: CGFloat] = [:]
    @State private var centeredId: String?
    @State private var lastHapticAt: Date = .distantPast
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { outer in
            let midX = outer.size.width / 2

            ZStack {
                LiquidChromeBackdrop()

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: cellSpacing) {
                            ForEach(stations) { station in
                                let offset = cellOffsets[station.stationId] ?? 999
                                let isCentered = station.stationId == (centeredId ?? selectedStationId)

                                MoodCapsuleCell(station: station, isCentered: isCentered, size: cellSize)
                                    .scaleEffect(arcScale(offset))
                                    .offset(y: arcOffsetY(offset))
                                    .opacity(arcOpacity(offset))
                                    .background(
                                        GeometryReader { cellGeo in
                                            Color.clear.preference(
                                                key: MoodCellOffsetKey.self,
                                                value: [station.stationId: cellGeo.frame(in: .named(space)).midX - midX]
                                            )
                                        }
                                    )
                                    .id(station.stationId)
                                    .onTapGesture {
                                        settleTask?.cancel()
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        withAnimation(AG.spring) {
                                            proxy.scrollTo(station.stationId, anchor: .center)
                                            centeredId = station.stationId
                                            selectedStationId = station.stationId
                                        }
                                        onSelect(station)
                                    }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, max(0, midX - cellSize / 2))
                        .padding(.top, 10)
                    }
                    .coordinateSpace(name: space)
                    .scrollTargetBehavior(.viewAligned)
                    .onPreferenceChange(MoodCellOffsetKey.self) { newOffsets in
                        cellOffsets = newOffsets
                        updateCenteredStation(newOffsets)
                    }
                    .onAppear {
                        centeredId = selectedStationId
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(selectedStationId, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(height: cellSize + 48)
    }

    // MARK: Arc math (по спецификации макета)

    private func arcScale(_ offset: CGFloat) -> CGFloat {
        let t = min(abs(offset) / 150, 1)
        return 1.0 - t * 0.2 // 1.0 в центре -> 0.8 по краям
    }

    private func arcOffsetY(_ offset: CGFloat) -> CGFloat {
        pow(offset / 80, 2) * 3 // боковые ячейки опускаются, образуя дугу
    }

    private func arcOpacity(_ offset: CGFloat) -> Double {
        let t = min(abs(offset) / 150, 1)
        return Double(1.0 - t * 0.5) // 1.0 в центре -> 0.5 по краям
    }

    // MARK: Centering, haptics (throttled to 1 tick / 45ms) and debounced commit

    private func updateCenteredStation(_ offsets: [String: CGFloat]) {
        guard let nearest = offsets.min(by: { abs($0.value) < abs($1.value) }) else { return }
        guard abs(nearest.value) < cellSize else { return }
        guard nearest.key != centeredId else { return }
        centeredId = nearest.key
        fireHapticTick()
        scheduleCommit(stationId: nearest.key)
    }

    private func fireHapticTick() {
        let now = Date()
        guard now.timeIntervalSince(lastHapticAt) >= 0.045 else { return }
        lastHapticAt = now
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The wheel keeps ticking through neighbours during a fast swipe; only
    /// the mood it actually settles on should start playing.
    private func scheduleCommit(stationId: String) {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            guard let station = stations.first(where: { $0.stationId == stationId }) else { return }
            selectedStationId = stationId
            onSelect(station)
        }
    }
}

private struct MoodCellOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Chrome capsule cell

private struct MoodCapsuleCell: View {
    let station: YandexMusicService.StationOption
    let isCentered: Bool
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Запечённый хром процедурно: слоистый металлический
                // градиент + бегущий блик. Прямая замена под реальный
                // PNG-ассет — Image("moodIcon_" + station.id) вместо ZStack.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                Color(white: 0.74),
                                Color(white: 0.90),
                                Color(white: 0.58)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.95), .black.opacity(0.28)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.1
                    )
                ShimmerOverlay(corner: size / 2)
                    .clipShape(Circle())

                Image(systemName: station.icon)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.70))
            }
            .frame(width: size, height: size)
            .scaleEffect(isCentered ? 1.15 : 1.0)
            .shadow(color: .white.opacity(isCentered ? 0.55 : 0), radius: isCentered ? 16 : 0)
            .shadow(color: .black.opacity(0.30), radius: 6, y: 3)
            .animation(AG.fastSpring, value: isCentered)

            Text(station.title)
                .font(AG.text(10.5, isCentered ? .bold : .medium))
                .foregroundStyle(isCentered ? AG.ink : AG.inkMuted)
                .lineLimit(1)
                .frame(width: size + 26)
        }
    }
}

// MARK: - Liquid chrome / silver background (reuses the existing FluidAura shader)

private struct LiquidChromeBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.09), Color(white: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            FluidWaveView(
                colors: [Color(white: 0.92), Color(white: 0.66), Color(white: 0.99)],
                isBackgroundMode: true
            )
            .opacity(0.55)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(AG.hairline, lineWidth: 0.8)
        )
        .allowsHitTesting(false)
    }
}
