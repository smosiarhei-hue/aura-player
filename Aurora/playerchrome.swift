import SwiftUI
import UIKit

// MARK: - Lyrics Sheet View with Synchronized Karaoke

struct LyricsSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics: Lyrics?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            karaokeBackdrop

            LyricsView(lyrics: lyrics, isLoading: isLoading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(AG.ink)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "Текст песни")
                            .font(AG.text(16, .semibold))
                            .foregroundStyle(AG.ink)
                            .lineLimit(1)
                        Text(player.currentTrack?.artist ?? "")
                            .font(AG.text(11, .medium))
                            .foregroundStyle(AG.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .colorScheme(.dark)
        .task(id: player.currentTrack?.id) {
            await load()
        }
    }

    @ViewBuilder
    private var karaokeBackdrop: some View {
        ZStack {
            AG.bg
            Color.clear
                .overlay {
                    if let track = player.currentTrack, let img = LibraryStore.cachedArtworkImage(for: track) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 60, opaque: true)
                            .opacity(0.45)
                    } else if let track = player.currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .blur(radius: 60, opaque: true)
                                    .opacity(0.45)
                            } else {
                                LinearGradient(colors: track.palette, startPoint: .top, endPoint: .bottom)
                            }
                        }
                    } else {
                        LinearGradient(colors: [AG.coal, AG.bg], startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipped()
        }
        .ignoresSafeArea()
    }

    private func load() async {
        guard let track = player.currentTrack else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            lyrics = try await LyricsService.shared.fetchLyrics(for: track)
        } catch {
            lyrics = nil
        }
    }
}

// MARK: - Marquee Title

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MarqueeText: View {
    let text: String
    var font: Font = .title2.weight(.bold)
    var color: Color = .white

    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    var body: some View {
        GeometryReader { container in
            let overflow = max(0, textWidth - container.size.width + 12)
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: geo.size.width)
                    }
                )
                .offset(x: animate ? -overflow : 0)
                .frame(width: container.size.width, alignment: .leading)
                .clipped()
                .animation(
                    overflow > 0 ? .easeInOut(duration: 4).repeatForever(autoreverses: true).delay(1.2) : nil,
                    value: animate
                )
                .onAppear { if overflow > 0 { animate = true } }
        }
        .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
        .frame(height: 32)
    }
}

// MARK: - Sleep Timer Sheet

struct SleepTimerSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 30

    private let options = [5, 10, 15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Время", selection: $minutes) {
                    ForEach(options, id: \.self) { m in
                        Text(String(m) + " мин").tag(m)
                    }
                }
                .pickerStyle(.wheel)

                if player.sleepTimerMinutes != nil {
                    Button(role: .destructive) {
                        player.setSleepTimer(minutes: nil)
                        dismiss()
                    } label: {
                        Label("Выключить таймер сна", systemImage: "moon.zzz")
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Таймер сна")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        player.setSleepTimer(minutes: minutes)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}

// MARK: - Queue Sheet View

struct QueueSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let cur = player.currentTrack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("СЕЙЧАС ИГРАЕТ")
                                .font(AG.text(11, .bold))
                                .tracking(1.2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)

                            HStack(spacing: 12) {
                                SmallArtwork(track: cur, size: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cur.title).font(AG.text(15, .semibold)).lineLimit(1).foregroundStyle(.primary)
                                    Text(cur.artist).font(AG.text(12, .regular)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "waveform")
                                    .foregroundStyle(AG.amber)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
                            .padding(.horizontal, 12)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ДАЛЕЕ В ОЧЕРЕДИ (" + String(player.queue.count) + ")")
                            .font(AG.text(11, .bold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        if player.queue.isEmpty {
                            Text("Очередь пуста. Выберите треки из каталога или медиатеки.")
                                .font(AG.text(14, .regular))
                                .foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            LazyVStack(spacing: 2) {
                                ForEach(player.queue) { track in
                                    Button {
                                        player.play(track)
                                    } label: {
                                        HStack(spacing: 12) {
                                            SmallArtwork(track: track, size: 44)
                                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(track.title).font(AG.text(14, .medium)).lineLimit(1).foregroundStyle(.primary)
                                                Text(track.artist).font(AG.text(11, .regular)).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                            if player.currentTrack?.id == track.id {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(AG.amber)
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            player.removeFromQueue(track)
                                        } label: {
                                            Label("Удалить из очереди", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("Очередь воспроизведения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Player EQ Sheet View

struct PlayerEQSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @Environment(\.dismiss) private var dismiss
    private let freqLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Toggle(isOn: $player.eqEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("10-полосный эквалайзер")
                                .font(AG.text(16, .semibold))
                            Text("31 Гц – 16 кГц · тонкая настройка звука")
                                .font(AG.text(12, .regular)).foregroundStyle(.secondary)
                        }
                    }
                    .tint(AG.amber)
                    .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Пресеты").font(AG.text(14, .semibold))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(EQPresets.all) { preset in
                                    let isActive = player.eqGains == preset.gains
                                    Button {
                                        withAnimation(.spring(response: 0.3)) {
                                            player.eqGains = preset.gains
                                        }
                                    } label: {
                                        Text(preset.name)
                                            .font(AG.text(13, isActive ? .semibold : .regular))
                                            .padding(.horizontal, 14).padding(.vertical, 8)
                                            .background(
                                                Capsule().fill(isActive
                                                    ? AnyShapeStyle(AG.emberGradient)
                                                    : AnyShapeStyle(Color.primary.opacity(0.08)))
                                            )
                                            .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 12) {
                        HStack {
                            Text("Полосы частот").font(AG.text(14, .semibold))
                            Spacer()
                            Button("Сбросить") {
                                withAnimation { player.eqGains = EQPresets.flat.gains }
                            }
                            .font(AG.text(12, .medium))
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
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Band Slider Component

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 6)
                    let fraction = CGFloat((value + 12) / 24)
                    Capsule()
                        .fill(LinearGradient(colors: [AG.amber, AG.flame], startPoint: .bottom, endPoint: .top))
                        .frame(width: 6, height: max(6, fraction * h))
                }
                .frame(height: h).frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let f = 1 - Float(min(max(v.location.y / h, 0), 1))
                            value = f * 24 - 12
                        }
                )

                Text(label)
                    .font(AG.text(10, .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
    }
}
