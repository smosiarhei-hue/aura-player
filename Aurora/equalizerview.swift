import SwiftUI

struct EqualizerView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var analyzer = SpectrumAnalyzer.shared

    private let freqLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    spectrumCard
                    toggleCard
                    presetsCard
                    bandsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Эквалайзер")
        }
    }

    // MARK: - Live spectrum

    private var spectrumCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Живой спектр").font(.subheadline.weight(.semibold))
                Spacer()
                if player.isPlaying {
                    Image(systemName: "waveform").foregroundStyle(SettingsStore.shared.accentColor)
                }
            }
            SpectrumView(barWidth: 6, maxHeight: 84).frame(maxWidth: .infinity)
        }
        .padding(16).glassCard()
    }

    // MARK: - Toggle

    private var toggleCard: some View {
        Toggle(isOn: $player.eqEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Эквалайзер").font(.subheadline.weight(.semibold))
                Text("10 полос · 31 Гц – 16 кГц").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).glassCard()
        .tint(SettingsStore.shared.accentColor)
    }

    // MARK: - Presets

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пресеты").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EQPresets.all, id: \.name) { preset in
                        let active = player.eqGains == preset.gains
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                player.eqGains = preset.gains
                            }
                        } label: {
                            Text(preset.name)
                                .font(Font.system(size: 13, weight: active ? .semibold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(
                                    active
                                    ? AnyShapeStyle(LinearGradient(colors: SettingsStore.shared.accent.colors, startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.primary.opacity(0.08))))
                                .foregroundStyle(active ? Color.white : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16).glassCard()
    }

    // MARK: - 10-band sliders

    private var bandsCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Полосы").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Сбросить") { withAnimation { player.eqGains = EQPresets.flat.gains } }
                    .font(.caption)
            }
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<10, id: \.self) { i in
                    BandSlider(
                        label: freqLabels[i],
                        value: Binding(get: { player.eqGains[i] }, set: { player.eqGains[i] = $0 })
                    )
                }
            }
        }
        .padding(16).glassCard()
    }
}

// MARK: - Band slider (vertical)

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.15)).frame(width: 5)
                    let fraction = CGFloat((value + 12) / 24)
                    Capsule()
                        .fill(LinearGradient(colors: SettingsStore.shared.accent.colors, startPoint: .bottom, endPoint: .top))
                        .frame(width: 5, height: max(4, fraction * h))
                    // zero line
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 18, height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom).offset(y: -h / 2)
                }
                .frame(height: h).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = 1 - Float(min(max(v.location.y / h, 0), 1))
                    value = f * 24 - 12
                })
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(height: 180)
    }
}