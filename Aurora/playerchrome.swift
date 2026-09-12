// Path: Aurora/playerchrome.swift

import SwiftUI
import UIKit

struct MarqueeText: View {
    let text: String
    var font: Font = .title2.weight(.bold)
    var color: Color = .white
    var height: CGFloat = 28
    var pauseDelay: Double = 2.0
    var scrollSpeed: Double = 32.0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>? = nil
    var body: some View {
        GeometryReader { geo in
            Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .background(GeometryReader { tGeo in
                    Color.clear.onAppear {
                        textWidth = tGeo.size.width; containerWidth = geo.size.width; restartAnimation()
                    }
                    .onChange(of: tGeo.size.width) { _, newWidth in textWidth = newWidth; restartAnimation() }
                })
                .offset(x: offset).frame(width: geo.size.width, height: geo.size.height, alignment: .leading).clipped()
                .onChange(of: geo.size.width) { _, newWidth in containerWidth = newWidth; restartAnimation() }
        }
        .frame(height: height).onChange(of: text) { _, _ in restartAnimation() }
        .onDisappear { animationTask?.cancel() }.accessibilityLabel(text)
    }
    private func restartAnimation() {
        animationTask?.cancel()
        offset = 0
        guard textWidth > (containerWidth + 4), containerWidth > 0 else { return }
        let diff = textWidth - containerWidth + 14
        let scrollDuration = Double(diff) / scrollSpeed
        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: scrollDuration)) { offset = -diff }
                try? await Task.sleep(nanoseconds: UInt64((scrollDuration + 2.0) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: scrollDuration)) { offset = 0 }
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
    @State private var player = ActivePlayerPresentation()
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    var body: some View {
        List {
            if let current = player.currentTrack {
                Section { queueRow(current, isCurrent: true).listRowBackground(Color.white.opacity(0.06)) }
                    header: { Text("Сейчас играет") }
            }
            Section {
                if player.queue.isEmpty {
                    ContentUnavailableView("Очередь пуста", systemImage: "music.note.list",
                        description: Text("Выберите треки из каталога или медиатеки.")).listRowBackground(Color.clear)
                } else {
                    ForEach(player.queue) { track in
                        Button {
                            Haptics.tap(.light)
                            PlaybackAudioSessionCoordinator.shared.activateForPlayback()
                            player.play(track)
                        } label: { queueRow(track, isCurrent: player.currentTrack?.id == track.id) }
                        .buttonStyle(.plain).listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { withAnimation { player.removeFromQueue(track) } }
                                label: { Label("Удалить", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { player.play(track) } label: { Label("Воспроизвести сейчас", systemImage: "play.fill") }
                            Button(role: .destructive) { withAnimation { player.removeFromQueue(track) } }
                                label: { Label("Удалить из очереди", systemImage: "trash") }
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
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode == .active ? "Готово" : "Изменить") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }.foregroundStyle(AG.amber).disabled(player.queue.isEmpty)
            }
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
            if isCurrent {
                Image(systemName: "waveform").foregroundStyle(AG.amber).symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            }
        }
        .frame(minHeight: 52).contentShape(Rectangle())
    }
}

struct PlayerEQSheetView: View {
    @State private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    private let frequencies = ["60 Hz", "150 Hz", "400 Hz", "1.0 kHz", "2.4 kHz", "15 kHz"]

    private var activePresetName: String {
        for preset in EQPresets.all {
            if isMatching(preset.gains, player.eqGains) {
                return preset.name
            }
        }
        return "Своя настройка"
    }

    private func isMatching(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if abs(a[i] - b[i]) > 0.1 { return false }
        }
        return true
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Top Bar with Close button
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.12), in: Circle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    // Title
                    Text("Эквалайзер")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)

                    // Interactive EQ Graph with dB values and Frequencies
                    InteractiveEQGraph(
                        frequencies: frequencies,
                        gains: Binding(
                            get: {
                                if player.eqGains.count == 6 { return player.eqGains }
                                return EQPresets.flat.gains
                            },
                            set: { player.eqGains = $0 }
                        ),
                        enabled: player.eqEnabled
                    )
                    .frame(height: 190)
                    .padding(.horizontal, 16)

                    // Toggle row
                    HStack {
                        Text("Эквалайзер")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: $player.eqEnabled)
                            .labelsHidden()
                            .tint(Color(red: 0.90, green: 0.98, blue: 0.12))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                    Divider().background(Color.white.opacity(0.12)).padding(.horizontal, 20)

                    // Presets List
                    VStack(spacing: 0) {
                        presetRow(title: "Своя настройка", isSelected: activePresetName == "Своя настройка") {
                            // Keep current custom gains
                        }

                        ForEach(EQPresets.all) { preset in
                            presetRow(title: preset.name, isSelected: activePresetName == preset.name) {
                                Haptics.tap(.light)
                                withAnimation(AG.spring) {
                                    player.eqGains = preset.gains
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.black)
    }

    private func presetRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InteractiveEQGraph: View {
    let frequencies: [String]
    @Binding var gains: [Float]
    let enabled: Bool

    private let yellow = Color(red: 0.90, green: 0.98, blue: 0.12)
    private let nodeCount = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let topLabelH: CGFloat = 24
            let bottomLabelH: CGFloat = 24
            let graphH = max(80, geo.size.height - topLabelH - bottomLabelH)
            let midY = topLabelH + graphH / 2
            let sidePad: CGFloat = 20
            let stepX = (w - 2 * sidePad) / CGFloat(max(1, nodeCount - 1))

            ZStack {
                // Top dB Labels
                HStack(spacing: 0) {
                    ForEach(0..<nodeCount, id: \.self) { i in
                        let g = i < gains.count ? gains[i] : 0
                        Text(formatDB(g))
                            .font(.system(size: 12, weight: .bold).monospacedDigit())
                            .foregroundStyle(enabled ? yellow : yellow.opacity(0.4))
                            .frame(width: stepX, alignment: .center)
                    }
                }
                .padding(.horizontal, sidePad - stepX / 2)
                .position(x: w / 2, y: topLabelH / 2)

                // 0 dB Guide Line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: w, y: midY))
                }
                .stroke(enabled ? yellow.opacity(0.7) : yellow.opacity(0.2), lineWidth: 1.5)

                // Continuous Spline Curve connecting nodes
                splinePath(width: w, midY: midY, graphH: graphH, sidePad: sidePad, stepX: stepX)
                    .stroke(enabled ? yellow : yellow.opacity(0.4), lineWidth: 2)

                // 6 Draggable Circular Nodes
                ForEach(0..<nodeCount, id: \.self) { i in
                    let x = sidePad + CGFloat(i) * stepX
                    let gain = CGFloat(i < gains.count ? gains[i] : 0)
                    let y = midY - (gain / 12.0) * (graphH / 2 - 12)

                    Circle()
                        .strokeBorder(enabled ? yellow : yellow.opacity(0.4), lineWidth: 2.5)
                        .background(Circle().fill(Color.black))
                        .frame(width: 22, height: 22)
                        .position(x: x, y: y)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    guard enabled, i < gains.count else { return }
                                    let deltaY = midY - val.location.y
                                    let maxRange = graphH / 2 - 12
                                    let rawGain = Float(deltaY / maxRange * 12.0)
                                    let clamped = min(12.0, max(-12.0, rawGain))
                                    if abs(clamped) < 0.3 {
                                        gains[i] = 0
                                    } else {
                                        gains[i] = round(clamped)
                                    }
                                }
                        )
                }

                // Bottom Frequency Labels
                HStack(spacing: 0) {
                    ForEach(0..<nodeCount, id: \.self) { i in
                        Text(frequencies[i])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(white: 0.6))
                            .frame(width: stepX, alignment: .center)
                    }
                }
                .padding(.horizontal, sidePad - stepX / 2)
                .position(x: w / 2, y: geo.size.height - bottomLabelH / 2)
            }
        }
    }

    private func formatDB(_ value: Float) -> String {
        let rounded = Int(round(value))
        if rounded > 0 { return "+\(rounded) dB" }
        return "\(rounded) dB"
    }

    private func splinePath(width: CGFloat, midY: CGFloat, graphH: CGFloat, sidePad: CGFloat, stepX: CGFloat) -> Path {
        var points: [CGPoint] = []
        for i in 0..<nodeCount {
            let x = sidePad + CGFloat(i) * stepX
            let gain = CGFloat(i < gains.count ? gains[i] : 0)
            let y = midY - (gain / 12.0) * (graphH / 2 - 12)
            points.append(CGPoint(x: x, y: y))
        }

        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: 0, y: first.y))
        path.addLine(to: first)

        for i in 0..<(points.count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let midX = (p0.x + p1.x) / 2
            path.addCurve(
                to: p1,
                control1: CGPoint(x: midX, y: p0.y),
                control2: CGPoint(x: midX, y: p1.y)
            )
        }

        if let last = points.last {
            path.addLine(to: CGPoint(x: width, y: last.y))
        }
        return path
    }
}
struct TactileButtonStyle: ButtonStyle {
    let scaleAmount: CGFloat
    init(scale: CGFloat = 0.86) { self.scaleAmount = scale }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scaleAmount : 1.0)
            .animation(AG.fastSpring, value: configuration.isPressed)
    }
}

#Preview("Queue") { NavigationStack { QueueSheetView() } }
