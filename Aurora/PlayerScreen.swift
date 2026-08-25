import SwiftUI

struct PlayerScreen: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var analyzer = SpectrumAnalyzer.shared
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    @State private var scrubValue: Double? = nil
    @State private var showQueue = false
    @State private var showEQ = false
    @State private var isDraggingScrubber = false

    private var palette: [Color] { player.currentTrack?.palette ?? Palette.seeded(42).colors }
    private var duration: Double { player.duration }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                artworkBackground
                    .ignoresSafeArea()
                Rectangle().fill(.black.opacity(0.35)).ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer().frame(height: geo.safeAreaInsets.top)

                    // Top bar: queue + EQ
                    HStack {
                        Spacer()
                        Button { showEQ = true } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { showQueue = true } label: {
                            Image(systemName: "text.justify")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.trailing, 12)

                    Spacer()

                    // Track info
                    VStack(spacing: 8) {
                        Text(player.currentTrack?.title ?? "Ничего не играет")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .padding(.horizontal, 32)

                    // Spectrum bar
                    if player.isPlaying {
                        SpectrumView(barWidth: 4, maxHeight: 32)
                            .frame(maxWidth: 200)
                            .padding(.top, 12)
                    }

                    // Scrubber
                    scrubber
                        .padding(.horizontal, 28).padding(.top, 16)

                    // Controls
                    controls
                        .padding(.horizontal, 36).padding(.top, 16)

                    Spacer().frame(height: max(geo.safeAreaInsets.bottom, 20))
                }
            }
        }
        .statusBarHidden()
        .colorScheme(.dark)
        .gesture(dismissGesture)
        .sheet(isPresented: $showQueue) { QueueSheet() }
        .sheet(isPresented: $showEQ) { PlayerEQSheet() }
    }

    // MARK: - Background

    private var artworkBackground: some View {
        AnimatedArtworkView(palette: palette)
            .blur(radius: 60).scaleEffect(1.4)
            .overlay(
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.5), .black.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom)
            )
            .animation(.easeInOut(duration: 1.5), value: palette)
    }

    // MARK: - Scrubber with haptic

    private var scrubber: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                let val = scrubValue ?? player.progress
                let frac = duration > 0 ? min(max(val / duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: max(4, w * frac), height: 4)
                    Circle().fill(.white)
                        .frame(width: isDraggingScrubber ? 18 : 14, height: isDraggingScrubber ? 18 : 14)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        .offset(x: min(max(0, w * frac - (isDraggingScrubber ? 9 : 7)), w - (isDraggingScrubber ? 18 : 14)))
                }
                .frame(height: 24).contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !isDraggingScrubber {
                                isDraggingScrubber = true
                                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                            }
                            let newFrac = max(0, min(1, v.location.x / max(w, 1)))
                            scrubValue = newFrac * duration
                            if settings.scrubHapticsEnabled {
                                let oldFrac = val / duration
                                if abs(newFrac - oldFrac) > 0.01 {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                }
                            }
                        }
                        .onEnded { _ in
                            if let s = scrubValue { player.seek(to: s); scrubValue = nil }
                            isDraggingScrubber = false
                        }
                )
            }
            .frame(height: 24)
            HStack {
                Text(player.formatted(scrubValue ?? player.progress))
                Spacer()
                Text("-" + player.formatted(duration - (scrubValue ?? player.progress)))
            }
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                player.shuffle.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: player.shuffle ? .bold : .regular))
                    .foregroundStyle(player.shuffle ? settings.accentColor : .white.opacity(0.7))
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer()
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer()
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer()
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer()
            Button {
                if settings.hapticsEnabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                player.repeatMode = RepeatMode(rawValue: (player.repeatMode.rawValue + 1) % 3) ?? .off
            } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 17, weight: player.repeatMode != .off ? .bold : .regular))
                    .foregroundStyle(player.repeatMode != .off ? settings.accentColor : .white.opacity(0.7))
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    // MARK: - Dismiss gesture

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { v in
                if v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width) {
                    dragOffset = v.translation.height
                }
            }
            .onEnded { v in
                if v.translation.height > 120 && abs(v.translation.height) > abs(v.translation.width) {
                    dismiss()
                }
                dragOffset = 0
            }
    }
}

// MARK: - EQ Sheet (inside player)

struct PlayerEQSheet: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = SettingsStore.shared
    private let freqLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Toggle
                    Toggle(isOn: $player.eqEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Эквалайзер").font(.subheadline.weight(.semibold))
                            Text("10 полос · 31 Гц – 16 кГц").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(settings.accentColor).padding(.horizontal, 16)

                    // Spectrum
                    if player.isPlaying {
                        VStack {
                            Text("Спектр").font(.caption).foregroundStyle(.secondary)
                            SpectrumView(barWidth: 5, maxHeight: 64)
                                .frame(maxWidth: .infinity).padding(.horizontal, 8)
                        }.padding(.horizontal, 16)
                    }

                    // Presets
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Пресеты").font(.subheadline.weight(.semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(EQPresets.all, id: \.name) { preset in
                                    let active = player.eqGains == preset.gains
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            player.eqGains = preset.gains
                                        }
                                    } label: {
                                        Text(preset.name)
                                            .font(.subheadline.weight(active ? .semibold : .regular))
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(
                                                Capsule().fill(active
                                                    ? AnyShapeStyle(settings.accentGradient)
                                                    : AnyShapeStyle(.primary.opacity(0.08))))
                                            .foregroundStyle(active ? .white : .primary)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.padding(.horizontal, 16)

                    // 10-band sliders
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
                    }.padding(.horizontal, 16)
                }
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Band slider

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(.primary.opacity(0.1)).frame(width: 5)
                    let fraction = CGFloat((value + 12) / 24)
                    Capsule()
                        .fill(LinearGradient(colors: SettingsStore.shared.accent.colors, startPoint: .bottom, endPoint: .top))
                        .frame(width: 5, height: max(4, fraction * h))
                    Rectangle().fill(.primary.opacity(0.15)).frame(width: 18, height: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom).offset(y: -h / 2)
                }
                .frame(height: h).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = 1 - Float(min(max(v.location.y / h, 0), 1))
                    value = f * 24 - 12
                })
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(height: 180)
    }
}

// MARK: - Queue sheet

struct QueueSheet: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(player.queue) { track in
                        Button { player.play(track) } label: {
                            HStack(spacing: 12) {
                                SmallArtwork(palette: track.palette, size: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading) {
                                    Text(track.title).lineLimit(1).font(.body).foregroundStyle(.primary)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if player.currentTrack?.id == track.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(SettingsStore.shared.accentColor).font(.caption)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                }.padding(.bottom, 80)
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}