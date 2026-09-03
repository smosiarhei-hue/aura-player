import SwiftUI
import UIKit

struct LyricsSheetView: View {
    @State private var player = PlayerCore.shared
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
                            .font(.headline).lineLimit(1).truncationMode(.tail)
                        Text(player.currentTrack?.artist ?? "")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
            }
        }
        .colorScheme(.dark)
        .task(id: player.currentTrack?.id) { await load() }
    }

    private var karaokeBackdrop: some View {
        ZStack {
            AG.bg
            Color.clear.overlay {
                if let track = player.currentTrack, let image = LibraryStore.cachedArtworkImage(for: track) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 60, opaque: true).opacity(0.45)
                } else if let track = player.currentTrack, let cover = track.coverURL, let url = URL(string: cover) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill).blur(radius: 60, opaque: true).opacity(0.45)
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

struct MarqueeText: View {
    let text: String
    var font: Font = .title2.weight(.bold)
    var color: Color = .white
    var height: CGFloat = 28
    var pauseDelay: Double = 2.0
    var scrollSpeed: Double = 32.0 // points per second

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>? = nil

    var body: some View {
        // Root in GeometryReader: unlike a ZStack, GeometryReader always
        // reports the width its parent proposes, never the ideal size of
        // its content. The old version wrapped a `.fixedSize(horizontal:
        // true)` Text (needed to measure the full un-clipped text width for
        // the scroll animation) in a ZStack — but a ZStack's own size is the
        // union of its children's sizes, so that fixedSize Text forced the
        // whole MarqueeText (and therefore the row of heart/wave/video-shot
        // buttons next to it) to report the full, un-clipped title/artist
        // width upward, pushing those buttons off-screen for long titles
        // instead of clipping the text and scrolling it in place.
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { tGeo in
                        Color.clear
                            .onAppear {
                                textWidth = tGeo.size.width
                                containerWidth = geo.size.width
                                restartAnimation()
                            }
                            .onChange(of: tGeo.size.width) { _, newWidth in
                                textWidth = newWidth
                                restartAnimation()
                            }
                    }
                )
                .offset(x: offset)
                // An explicit frame(width:) always reports exactly that
                // size upward regardless of the child's ideal size — this
                // is what actually keeps MarqueeText, and its siblings,
                // inside the available space.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .onChange(of: geo.size.width) { _, newWidth in
                    containerWidth = newWidth
                    restartAnimation()
                }
        }
        .frame(height: height)
        .onChange(of: text) { _, _ in
            restartAnimation()
        }
        .onDisappear {
            animationTask?.cancel()
        }
        .accessibilityLabel(text)
    }

    private func restartAnimation() {
        animationTask?.cancel()
        offset = 0
        guard textWidth > (containerWidth + 4), containerWidth > 0 else { return }

        let diff = textWidth - containerWidth + 14
        let scrollDuration = Double(diff) / scrollSpeed

        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                // 1. Постоять на месте в самом начале (2 сек)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }

                // 2. Плавно доехать до самого конца строки
                withAnimation(.easeInOut(duration: scrollDuration)) {
                    offset = -diff
                }

                // 3. Дождаться окончания движения + постоять в конце (2 сек)
                try? await Task.sleep(nanoseconds: UInt64((scrollDuration + 2.0) * 1_000_000_000))
                guard !Task.isCancelled else { break }

                // 4. Плавно вернуться в самое начало
                withAnimation(.easeInOut(duration: scrollDuration)) {
                    offset = 0
                }

                // 5. Дождаться окончания возврата
                try? await Task.sleep(nanoseconds: UInt64(scrollDuration * 1_000_000_000))
            }
        }
    }
}

struct SleepTimerSheetView: View {
    @State private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30
    private let options = [5, 10, 15, 30, 45, 60, 90, 120]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("Время", selection: $minutes) {
                    ForEach(options, id: \.self) { Text(String($0) + " мин").tag($0) }
                }.pickerStyle(.wheel)
                if player.sleepTimerMinutes != nil {
                    Button("Выключить таймер сна", role: .destructive) { player.setSleepTimer(minutes: nil); dismiss() }
                        .frame(minHeight: 44).padding(.bottom, 12)
                }
            }
            .navigationTitle("Таймер сна").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { player.setSleepTimer(minutes: minutes); dismiss() } }
            }
        }
        .presentationDetents([.height(320)]).presentationDragIndicator(.visible)
    }
}

struct QueueSheetView: View {
    @State private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            if let current = player.currentTrack {
                Section { queueRow(current, isCurrent: true).listRowBackground(Color.white.opacity(0.06)) } header: { Text("Сейчас играет") }
            }
            Section {
                if player.queue.isEmpty {
                    ContentUnavailableView("Очередь пуста", systemImage: "music.note.list", description: Text("Выберите треки из каталога или медиатеки.")).listRowBackground(Color.clear)
                } else {
                    ForEach(player.queue) { track in
                        Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); PlaybackAudioSessionCoordinator.shared.activateForPlayback(); player.play(track) } label: {
                            queueRow(track, isCurrent: player.currentTrack?.id == track.id)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { withAnimation { player.removeFromQueue(track) } } label: { Label("Удалить", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { player.play(track) } label: { Label("Воспроизвести сейчас", systemImage: "play.fill") }
                            Button(role: .destructive) { withAnimation { player.removeFromQueue(track) } } label: { Label("Удалить из очереди", systemImage: "trash") }
                        }
                    }
                    .onMove { player.queue.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { player.queue.remove(atOffsets: $0) }
                }
            } header: { HStack { Text("Далее в очереди"); Spacer(); Text(String(player.queue.count)) } }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).environment(\.editMode, $editMode)
        .navigationTitle("Очередь").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button(editMode == .active ? "Готово" : "Изменить") { withAnimation { editMode = editMode == .active ? .inactive : .active } }.foregroundStyle(AG.amber).disabled(player.queue.isEmpty) }
            ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() }.foregroundStyle(AG.amber) }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationContentInteraction(.scrolls)
    }

    private func queueRow(_ track: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            SmallArtwork(track: track, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).foregroundStyle(isCurrent ? AG.amber : .primary).lineLimit(1).truncationMode(.tail)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent { Image(systemName: "waveform").foregroundStyle(AG.amber).symbolEffect(.variableColor.iterative, isActive: player.isPlaying) }
        }
        .frame(minHeight: 52).contentShape(Rectangle())
    }
}

struct PlayerEQSheetView: View {
    @State private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 44
    private let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    private var tapHeight: CGFloat { max(44, min(controlHeight, 56)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Toggle("10-полосный эквалайзер", isOn: $player.eqEnabled)
                    .tint(AG.amber).frame(minHeight: tapHeight)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Пресеты").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(EQPresets.all) { preset in
                                Button(preset.name) { withAnimation(.spring(response: 0.3)) { player.eqGains = preset.gains } }
                                    .buttonStyle(.bordered).tint(player.eqGains == preset.gains ? AG.amber : .secondary)
                                    .frame(minHeight: tapHeight)
                            }
                        }.padding(.vertical, 2)
                    }
                }

                HStack {
                    Text("Полосы частот").font(.headline)
                    Spacer()
                    Button("Сбросить") { player.eqGains = EQPresets.flat.gains }.frame(minHeight: tapHeight)
                }

                // Ten 44pt touch lanes cannot fit safely on an iPhone side by side.
                // Horizontal scrolling preserves readable labels and accurate drag targets.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 8) {
                        ForEach(0..<10, id: \.self) { index in
                            BandSlider(label: labels[index], value: Binding(get: { player.eqGains[index] }, set: { player.eqGains[index] = $0 }))
                                .frame(width: 44)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(minHeight: 230)
            }
            .padding(.horizontal, 20).padding(.top, 20)
            .safeAreaPadding(.bottom, 12)
        }
        .navigationTitle("Эквалайзер").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() }.foregroundStyle(AG.amber) } }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

struct BandSlider: View {
    let label: String
    @Binding var value: Float

    var body: some View {
        GeometryReader { geometry in
            let trackHeight = max(150, geometry.size.height - 30)
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(width: 8)
                    let fraction = CGFloat((value + 12) / 24)
                    Capsule().fill(AG.emberGradient).frame(width: 8, height: max(8, fraction * trackHeight))
                }
                .frame(height: trackHeight).frame(maxWidth: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let fraction = 1 - Float(min(max(gesture.location.y / trackHeight, 0), 1))
                    value = fraction * 24 - 12
                })
                Text(label).font(.caption2).foregroundStyle(.secondary).frame(minHeight: 18)
            }
        }
        .frame(height: 210)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + " герц")
        .accessibilityValue(String(format: "%.0f децибел", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(12, value + 1)
            case .decrement: value = max(-12, value - 1)
            @unknown default: break
            }
        }
    }
}

// MARK: - Tactile Spring Bounce Button Style (Apple Music iOS Standard)

struct TactileButtonStyle: ButtonStyle {
    let scaleAmount: CGFloat

    init(scale: CGFloat = 0.86) {
        self.scaleAmount = scale
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
