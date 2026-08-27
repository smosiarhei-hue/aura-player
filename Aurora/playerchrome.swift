import SwiftUI
import UIKit

// MARK: - Lyrics

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
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "Текст песни")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .colorScheme(.dark)
        .task(id: player.currentTrack?.id) { await load() }
    }

    private var karaokeBackdrop: some View {
        ZStack {
            AG.bg
            Color.clear
                .overlay {
                    if let track = player.currentTrack,
                       let image = LibraryStore.cachedArtworkImage(for: track) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 60, opaque: true)
                            .opacity(0.45)
                    } else if let track = player.currentTrack,
                              let cover = track.coverURL,
                              let url = URL(string: cover) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
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
        lyrics = try? await LyricsService.shared.fetchLyrics(for: track)
    }
}

// MARK: - Stable player title

/// Стабильная системная строка без GeometryReader-сдвигов.
/// Длинные названия аккуратно сокращаются, а VoiceOver получает полный текст.
struct MarqueeText: View {
    let text: String
    var font: Font = .title2.weight(.bold)
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .accessibilityLabel(text)
    }
}

// MARK: - Sleep timer

struct SleepTimerSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30

    private let options = [5, 10, 15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Время", selection: $minutes) {
                    ForEach(options, id: \.self) { value in
                        Text(String(value) + " мин").tag(value)
                    }
                }
                .pickerStyle(.wheel)

                if player.sleepTimerMinutes != nil {
                    Button("Выключить таймер сна", role: .destructive) {
                        player.setSleepTimer(minutes: nil)
                        dismiss()
                    }
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

// MARK: - Queue

struct QueueSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let current = player.currentTrack {
                        Text("СЕЙЧАС ИГРАЕТ")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)

                        queueRow(current, isCurrent: true)
                    }

                    Text("ДАЛЕЕ В ОЧЕРЕДИ (" + String(player.queue.count) + ")")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if player.queue.isEmpty {
                        ContentUnavailableView(
                            "Очередь пуста",
                            systemImage: "music.note.list",
                            description: Text("Выберите треки из каталога или медиатеки.")
                        )
                    } else {
                        ForEach(player.queue) { track in
                            Button {
                                player.play(track)
                            } label: {
                                queueRow(track, isCurrent: player.currentTrack?.id == track.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Удалить из очереди", systemImage: "trash", role: .destructive) {
                                    player.removeFromQueue(track)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func queueRow(_ track: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            SmallArtwork(track: track, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(AG.amber)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

// MARK: - Equalizer

struct PlayerEQSheetView: View {
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    private let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Toggle("10-полосный эквалайзер", isOn: $player.eqEnabled)
                        .tint(AG.amber)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Пресеты").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(EQPresets.all) { preset in
                                    Button(preset.name) {
                                        withAnimation(.spring(response: 0.3)) {
                                            player.eqGains = preset.gains
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(player.eqGains == preset.gains ? AG.amber : .secondary)
                                }
                            }
                        }
                    }

                    HStack {
                        Text("Полосы частот").font(.headline)
                        Spacer()
                        Button("Сбросить") { player.eqGains = EQPresets.flat.gains }
                    }

                    HStack(alignment: .center, spacing: 6) {
                        ForEach(0..<10, id: \.self) { index in
                            BandSlider(
                                label: labels[index],
                                value: Binding(
                                    get: { player.eqGains[index] },
                                    set: { player.eqGains[index] = $0 }
                                )
                            )
                        }
                    }
                }
                .padding(20)
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

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 6)
                    let fraction = CGFloat((value + 12) / 24)
                    Capsule()
                        .fill(AG.emberGradient)
                        .frame(width: 6, height: max(6, fraction * height))
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = 1 - Float(min(max(gesture.location.y / height, 0), 1))
                            value = fraction * 24 - 12
                        }
                )

                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
    }
}
