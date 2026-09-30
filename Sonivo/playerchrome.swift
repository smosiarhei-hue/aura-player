// Path: Sonivo/playerchrome.swift

import Observation
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
    @Bindable private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    private struct PresetItem: Identifiable {
        let id: Int
        let title: String
        let minutes: Int
        let icon: String
    }

    private let presets: [PresetItem] = [
        PresetItem(id: 15, title: "15 минут", minutes: 15, icon: "timer"),
        PresetItem(id: 30, title: "30 минут", minutes: 30, icon: "timer"),
        PresetItem(id: 45, title: "45 минут", minutes: 45, icon: "timer"),
        PresetItem(id: 60, title: "1 час", minutes: 60, icon: "timer"),
        PresetItem(id: 90, title: "1.5 часа", minutes: 90, icon: "timer"),
        PresetItem(id: 120, title: "2 часа", minutes: 120, icon: "timer")
    ]

    private var endOfTrackMinutes: Int? {
        guard player.isPlaying, player.duration > player.progress else { return nil }
        let remaining = player.duration - player.progress
        return max(1, Int(ceil(remaining / 60.0)))
    }

    var body: some View {
        ZStack {
            SonivoScreenBackground(colors: [SN.ember, SN.bgRaised], showsMesh: false)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // 1. Active Timer Header Card (if running)
                    if let remaining = player.sleepTimerRemaining, remaining > 0 {
                        activeTimerCard(remaining: remaining)
                            .padding(.top, 10)
                    }

                    // 2. Presets List (Native Apple Style)
                    VStack(spacing: 0) {
                        if let eot = endOfTrackMinutes {
                            presetRow(
                                title: "По окончании трека",
                                detail: "\(eot) мин",
                                icon: "forward.end.fill",
                                isSelected: false
                            ) {
                                selectPreset(minutes: eot)
                            }

                            Divider().background(Color.white.opacity(0.08))
                        }

                        ForEach(presets) { preset in
                            let isSelected = (player.sleepTimerMinutes == preset.minutes)
                            presetRow(
                                title: preset.title,
                                detail: nil,
                                icon: preset.icon,
                                isSelected: isSelected
                            ) {
                                selectPreset(minutes: preset.minutes)
                            }

                            if preset.id != presets.last?.id {
                                Divider().background(Color.white.opacity(0.08))
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(SN.card.opacity(0.70))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                            )
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, player.sleepTimerRemaining != nil ? 4 : 12)

                    // 3. Turn off timer button (if active)
                    if player.sleepTimerRemaining != nil {
                        Button(role: .destructive) {
                            Haptics.tap(.light)
                            player.cancelSleepTimer()
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                Text("Выключить таймер сна")
                            }
                            .font(SN.text(.body, .semibold))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.red.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))
                        .padding(.horizontal, 16)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Таймер сна")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") { dismiss() }
                    .font(SN.text(.body, .bold))
                    .foregroundStyle(SN.amber)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    private func selectPreset(minutes: Int) {
        Haptics.tap(.medium)
        withAnimation(SN.spring) {
            player.setSleepTimer(minutes: minutes)
        }
        dismiss()
    }

    private func activeTimerCard(remaining: Double) -> some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.orange)
                    Text("Таймер активен")
                        .font(SN.text(.headline, .bold))
                        .foregroundStyle(SN.ink)
                }
                Spacer()
                if let totalMins = player.sleepTimerMinutes {
                    Text("на \(totalMins) мин")
                        .font(SN.text(.subheadline, .medium))
                        .foregroundStyle(SN.inkMuted)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(player.sleepTimerFormatted ?? "0:00")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.orange)
                Text("до отключения")
                    .font(SN.text(.subheadline, .medium))
                    .foregroundStyle(SN.inkMuted)
                Spacer()
            }

            // Progress bar
            if let totalMinutes = player.sleepTimerMinutes, totalMinutes > 0 {
                let totalSec = Double(totalMinutes * 60)
                let progress = max(0.0, min(1.0, remaining / totalSec))
                GeometryReader { geo in
                    let barW = max(0.0, min(geo.size.width, geo.size.width * progress))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 6)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange, Color.yellow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: barW, height: 6)
                    }
                }
                .frame(height: 6)
            }

            // Quick extend buttons
            HStack(spacing: 8) {
                ForEach([5, 15, 30], id: \.self) { ext in
                    Button {
                        Haptics.tap(.light)
                        withAnimation(SN.spring) {
                            player.extendSleepTimer(byMinutes: ext)
                        }
                    } label: {
                        Text("+\(ext) мин")
                            .font(SN.text(.caption, .semibold))
                            .foregroundStyle(SN.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SN.card.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private func presetRow(title: String, detail: String?, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.orange : SN.inkMuted)
                    .frame(width: 24)

                Text(title)
                    .font(SN.text(.body, isSelected ? .bold : .regular))
                    .foregroundStyle(SN.ink)

                Spacer()

                if let detail {
                    Text(detail)
                        .font(SN.text(.subheadline, .regular))
                        .foregroundStyle(SN.inkMuted)
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.orange)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))
    }
}

struct QueueSheetView: View {
    @State private var player = ActivePlayerPresentation()
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    var body: some View {
        List {
            if let current = player.currentTrack {
                Section { queueRow(current, isCurrent: true).listRowBackground(SN.card.opacity(0.82)) }
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
                        .buttonStyle(CardPressStyle(scale: 0.98, haptic: true)).listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
        .background(SonivoScreenBackground(colors: [SN.ember, SN.bgRaised], showsMesh: false))
        .listRowSeparatorTint(.white.opacity(0.10))
        .navigationTitle("Очередь").navigationBarTitleDisplayMode(.inline)
        .task { await player.observeTimeline() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(editMode == .active ? "Готово" : "Изменить") {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                }.foregroundStyle(SN.amber).disabled(player.queue.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() }.foregroundStyle(SN.amber) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(.ultraThinMaterial)
    }
    private func queueRow(_ track: Track, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            SmallArtwork(track: track, size: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).foregroundStyle(isCurrent ? SN.amber : .primary).lineLimit(1).truncationMode(.tail)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent {
                Image(systemName: "waveform").foregroundStyle(SN.amber).symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            }
        }
        .frame(minHeight: 52).contentShape(Rectangle())
    }
}

struct PlayerEQSheetView: View {
    @Bindable private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    private let frequencies = ["20", "40", "60", "90", "160", "400", "1k", "2.5k", "6k", "16k"]

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
            SonivoScreenBackground(colors: [SN.ember, SN.bgRaised], showsMesh: false)

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
                                .foregroundStyle(SN.ink)
                                .frame(width: 32, height: 32)
                                .background(SN.ink.opacity(0.12), in: Circle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Эквалайзер")
                            .font(SN.display(.largeTitle, .heavy))
                            .foregroundStyle(SN.ink)
                        Text(player.eqEnabled ? "Включен" : "Выключен")
                            .font(SN.text(.subheadline, .medium))
                            .foregroundStyle(player.eqEnabled ? SN.positive : SN.inkMuted)
                    }
                    .padding(.horizontal, 20)

                    // Interactive EQ Graph with dB values and Frequencies
                    InteractiveEQGraph(
                        frequencies: frequencies,
                        gains: Binding(
                            get: {
                                if player.eqGains.count == 10 { return player.eqGains }
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
                            .font(SN.text(.body, .semibold))
                            .foregroundStyle(SN.ink)
                        Spacer()
                        Toggle("", isOn: $player.eqEnabled)
                            .labelsHidden()
                            .tint(SN.amber)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                    Divider().background(SN.ink.opacity(0.12)).padding(.horizontal, 20)

                    // Presets List
                    VStack(spacing: 0) {
                        presetRow(title: "Своя настройка", isSelected: activePresetName == "Своя настройка") {
                            // Keep current custom gains
                        }

                        ForEach(EQPresets.all) { preset in
                            presetRow(title: preset.name, isSelected: activePresetName == preset.name) {
                                Haptics.tap(.light)
                                withAnimation(SN.spring) {
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
        .presentationBackground(.ultraThinMaterial)
    }

    private func presetRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(SN.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SN.ink)
                }
            }
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))
    }
}

struct InteractiveEQGraph: View {
    let frequencies: [String]
    @Binding var gains: [Float]
    let enabled: Bool

    @State private var activeBandIndex: Int? = nil

    private let yellow = Color(red: 0.90, green: 0.98, blue: 0.12)
    private let nodeCount = 10
    private let maxGain: CGFloat = 20.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let topLabelH: CGFloat = 24
            let bottomLabelH: CGFloat = 26
            let graphH = max(80, geo.size.height - topLabelH - bottomLabelH)
            let midY = topLabelH + graphH / 2
            let sidePad: CGFloat = 16
            let stepX = (w - 2 * sidePad) / CGFloat(max(1, nodeCount - 1))

            ZStack {
                // Vertical accent guide for active band
                if let active = activeBandIndex {
                    let activeX = sidePad + CGFloat(active) * stepX
                    Path { path in
                        path.move(to: CGPoint(x: activeX, y: topLabelH - 2))
                        path.addLine(to: CGPoint(x: activeX, y: geo.size.height - bottomLabelH + 2))
                    }
                    .stroke(yellow.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .animation(.spring(response: 0.25, dampingFraction: 0.75), value: active)
                }

                // Top dB Labels
                HStack(spacing: 0) {
                    ForEach(0..<nodeCount, id: \.self) { i in
                        let g = i < gains.count ? gains[i] : 0
                        let isActive = (activeBandIndex == i)
                        Text(formatDB(g))
                            .font(.system(size: isActive ? 12 : 10, weight: isActive ? .heavy : .bold).monospacedDigit())
                            .foregroundStyle(isActive ? yellow : (enabled ? yellow.opacity(0.8) : yellow.opacity(0.35)))
                            .scaleEffect(isActive ? 1.35 : 1.0)
                            .padding(.horizontal, isActive ? 4 : 0)
                            .padding(.vertical, isActive ? 2 : 0)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(isActive ? 0.70 : 0.0))
                                    .overlay(
                                        Capsule().stroke(yellow.opacity(isActive ? 0.45 : 0.0), lineWidth: 1)
                                    )
                            )
                            .frame(width: stepX, alignment: .center)
                            .zIndex(isActive ? 5 : 1)
                            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isActive)
                    }
                }
                .padding(.horizontal, sidePad - stepX / 2)
                .position(x: w / 2, y: topLabelH / 2)

                // 0 dB Guide Line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: w, y: midY))
                }
                .stroke(enabled ? yellow.opacity(0.65) : yellow.opacity(0.2), lineWidth: 1.5)

                // Continuous Spline Curve connecting nodes
                splinePath(width: w, midY: midY, graphH: graphH, sidePad: sidePad, stepX: stepX)
                    .stroke(enabled ? yellow : yellow.opacity(0.4), lineWidth: 2)

                // 10 Draggable Circular Nodes with native scaling on selection
                ForEach(0..<nodeCount, id: \.self) { i in
                    let x = sidePad + CGFloat(i) * stepX
                    let gain = CGFloat(i < gains.count ? gains[i] : 0)
                    let y = midY - (gain / maxGain) * (graphH / 2 - 12)
                    let isActive = (activeBandIndex == i)

                    ZStack {
                        // Luminous halo around active node
                        if isActive {
                            Circle()
                                .stroke(yellow.opacity(0.35), lineWidth: 2.0)
                                .frame(width: 36, height: 36)
                                .scaleEffect(1.2)
                        }

                        // Core node circle
                        Circle()
                            .fill(isActive ? yellow : SN.bg)
                            .overlay(
                                Circle().stroke(enabled ? yellow : yellow.opacity(0.4), lineWidth: isActive ? 3.0 : 2.5)
                            )
                            .overlay(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 5, height: 5)
                                    .opacity(isActive ? 1.0 : 0.0)
                            )
                            .frame(width: 18, height: 18)
                            .scaleEffect(isActive ? 1.65 : 1.0)
                            .shadow(color: yellow.opacity(isActive ? 0.95 : 0.0), radius: isActive ? 12 : 0)
                    }
                    .position(x: x, y: y)
                    .zIndex(isActive ? 10 : 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isActive)
                }

                // Bottom Frequency Labels with native enlargement when selected
                HStack(spacing: 0) {
                    ForEach(0..<nodeCount, id: \.self) { i in
                        let isActive = (activeBandIndex == i)
                        Button {
                            guard enabled else { return }
                            Haptics.tap(.light)
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                activeBandIndex = i
                            }
                        } label: {
                            Text(frequencies[i])
                                .font(.system(size: isActive ? 13 : 10, weight: isActive ? .heavy : .semibold))
                                .foregroundStyle(isActive ? yellow : Color(white: enabled ? 0.70 : 0.35))
                                .scaleEffect(isActive ? 1.35 : 1.0)
                                .padding(.horizontal, isActive ? 6 : 0)
                                .padding(.vertical, isActive ? 2 : 0)
                                .background(
                                    Capsule()
                                        .fill(yellow.opacity(isActive ? 0.22 : 0.0))
                                        .overlay(
                                            Capsule().stroke(yellow.opacity(isActive ? 0.45 : 0.0), lineWidth: 1)
                                        )
                                )
                                .frame(width: stepX, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .zIndex(isActive ? 5 : 1)
                        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isActive)
                    }
                }
                .padding(.horizontal, sidePad - stepX / 2)
                .position(x: w / 2, y: geo.size.height - bottomLabelH / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        guard enabled else { return }
                        let touchedIndex = min(nodeCount - 1, max(0, Int(round((val.location.x - sidePad) / stepX))))
                        if activeBandIndex != touchedIndex {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                activeBandIndex = touchedIndex
                            }
                            Haptics.tap(.light)
                        }

                        guard touchedIndex < gains.count else { return }
                        let maxRange = graphH / 2 - 12
                        guard maxRange > 1, val.location.y.isFinite else { return }
                        let deltaY = midY - val.location.y
                        let rawGain = Float((deltaY / maxRange) * maxGain)
                        guard rawGain.isFinite else { return }
                        let clamped = min(Float(maxGain), max(-Float(maxGain), rawGain))
                        let newGain: Float = abs(clamped) < 0.4 ? 0 : round(clamped)
                        guard newGain.isFinite else { return }

                        if gains[touchedIndex] != newGain {
                            if (gains[touchedIndex] > 0 && newGain <= 0) || (gains[touchedIndex] < 0 && newGain >= 0) {
                                Haptics.tap(.light)
                            }
                            gains[touchedIndex] = newGain
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            activeBandIndex = nil
                        }
                        PlayerCore.shared.saveEQ()
                    }
            )
        }
    }

    private func formatDB(_ value: Float) -> String {
        let rounded = Int(round(value))
        if rounded > 0 { return "+\(rounded)" }
        return "\(rounded)"
    }

    private func splinePath(width: CGFloat, midY: CGFloat, graphH: CGFloat, sidePad: CGFloat, stepX: CGFloat) -> Path {
        var points: [CGPoint] = []
        for i in 0..<nodeCount {
            let x = sidePad + CGFloat(i) * stepX
            let gain = CGFloat(i < gains.count ? gains[i] : 0)
            let y = midY - (gain / maxGain) * (graphH / 2 - 10)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(scale: CGFloat = 0.95) { self.scaleAmount = scale }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? scaleAmount : 1.0))
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(SN.fastSpring, value: configuration.isPressed)
    }
}

#Preview("Queue") { NavigationStack { QueueSheetView() } }
