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
    @State private var activeBandIndex: Int? = nil

    private var activePresetName: String {
        for preset in EQPresets.all {
            if isMatching(preset.gains, player.eqGains) {
                return preset.name
            }
        }
        return "Своя настройка"
    }

    private var isFlat: Bool {
        isMatching(EQPresets.flat.gains, player.eqGains)
    }

    private func isMatching(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if abs(a[i] - b[i]) > 0.2 { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoScreenBackground(colors: [SN.ember, SN.bgRaised], showsMesh: false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        // Master Toggle Card
                        masterToggleCard

                        // Live Response Curve Visualizer
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("АЧХ ФИЛЬТРА")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .tracking(0.8)
                                    .foregroundStyle(SN.inkFaint)
                                Spacer()
                                Text(activePresetName)
                                    .font(SN.text(.caption, .semibold))
                                    .foregroundStyle(SN.amber)
                            }
                            .padding(.horizontal, 4)

                            EQResponseCurveView(
                                frequencies: frequencies,
                                gains: player.eqGains,
                                enabled: player.eqEnabled,
                                activeBandIndex: activeBandIndex
                            )
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 16)

                        // 10-Band Vertical Faders
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("ПОЛОСЫ ЭКВАЛАЙЗЕРА")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .tracking(0.8)
                                    .foregroundStyle(SN.inkFaint)
                                Spacer()
                                Text("±12 дБ")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(SN.inkMuted)
                            }
                            .padding(.horizontal, 20)

                            EQFadersDeckView(
                                frequencies: frequencies,
                                gains: Binding(
                                    get: {
                                        if player.eqGains.count == 10 { return player.eqGains }
                                        return PlayerCore.normalized(player.eqGains)
                                    },
                                    set: { player.eqGains = $0 }
                                ),
                                enabled: player.eqEnabled,
                                activeBandIndex: $activeBandIndex
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(SN.card.opacity(0.85))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .padding(.horizontal, 16)
                        }

                        // Quick Presets Horizontal Carousel
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ПРЕСЕТЫ")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(SN.inkFaint)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(EQPresets.all) { preset in
                                        let isSel = activePresetName == preset.name
                                        Button {
                                            applyPreset(preset)
                                        } label: {
                                            HStack(spacing: 6) {
                                                if isSel {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 11, weight: .bold))
                                                }
                                                Text(preset.name)
                                                    .font(SN.text(.subheadline, isSel ? .bold : .medium))
                                            }
                                            .foregroundStyle(isSel ? Color.black : SN.ink)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(
                                                Capsule()
                                                    .fill(isSel ? SN.amber : Color.white.opacity(0.10))
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }

                        // Presets List
                        VStack(spacing: 0) {
                            ForEach(EQPresets.all) { preset in
                                let isSel = activePresetName == preset.name
                                Button {
                                    applyPreset(preset)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(isSel ? SN.amber : SN.inkMuted)

                                        Text(preset.name)
                                            .font(SN.text(.body, isSel ? .bold : .regular))
                                            .foregroundStyle(SN.ink)

                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(height: 50)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(CardPressStyle(scale: 0.98, haptic: false))

                                if preset.id != EQPresets.all.last?.id {
                                    Divider()
                                        .background(Color.white.opacity(0.06))
                                        .padding(.leading, 46)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(SN.card.opacity(0.85))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !isFlat {
                        Button("Сбросить") {
                            Haptics.tap(.medium)
                            withAnimation(SN.spring) {
                                player.eqGains = EQPresets.flat.gains
                            }
                        }
                        .font(SN.text(.subheadline, .medium))
                        .foregroundStyle(SN.inkMuted)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                        .font(SN.text(.body, .bold))
                        .foregroundStyle(SN.amber)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    private func applyPreset(_ preset: EQPreset) {
        Haptics.tap(.light)
        withAnimation(SN.spring) {
            player.eqGains = preset.gains
        }
    }

    private var masterToggleCard: some View {
        VStack(spacing: 12) {
            // Master EQ Switch
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(player.eqEnabled ? SN.amber.opacity(0.20) : Color.white.opacity(0.08))
                        .frame(width: 44, height: 44)
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(player.eqEnabled ? SN.amber : SN.inkMuted)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Эквалайзер")
                        .font(SN.text(.body, .bold))
                        .foregroundStyle(SN.ink)
                    Text(player.eqEnabled ? (player.isEQEffectivelyActive ? "10-полосная обработка активна" : "Приостановлен (динамик)") : "Выключен (исходный звук)")
                        .font(SN.text(.caption, .regular))
                        .foregroundStyle(player.isEQEffectivelyActive ? SN.positive : (player.eqEnabled ? SN.amber : SN.inkMuted))
                }

                Spacer()

                Toggle("", isOn: $player.eqEnabled)
                    .labelsHidden()
                    .tint(SN.amber)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Smart Headphone EQ Toggle
            HStack(spacing: 12) {
                Image(systemName: "headphones")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(player.eqHeadphonesOnly ? SN.amber : SN.inkMuted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Только в наушниках")
                        .font(SN.text(.subheadline, .medium))
                        .foregroundStyle(SN.ink)
                    Text("Отключает эквалайзер на динамике телефона для защиты от искажений")
                        .font(SN.text(.caption2, .regular))
                        .foregroundStyle(SN.inkMuted)
                }

                Spacer()

                Toggle("", isOn: $player.eqHeadphonesOnly)
                    .labelsHidden()
                    .tint(SN.amber)
            }

            // Route Status Pill
            HStack(spacing: 8) {
                Circle()
                    .fill(player.isEQEffectivelyActive ? Color.green : (player.eqEnabled ? Color.orange : Color.gray))
                    .frame(width: 7, height: 7)

                if !player.eqEnabled {
                    Text("Эквалайзер отключен")
                        .font(SN.text(.caption, .medium))
                        .foregroundStyle(SN.inkMuted)
                } else if player.isHeadphonesConnected {
                    Text("🎧 Наушники подключены • Эквалайзер активен")
                        .font(SN.text(.caption, .medium))
                        .foregroundStyle(SN.ink)
                } else if player.eqHeadphonesOnly {
                    Text("📱 Динамик телефона • Эквалайзер отключен (Flat)")
                        .font(SN.text(.caption, .medium))
                        .foregroundStyle(SN.inkMuted)
                } else {
                    Text("📱 Динамик телефона • Эквалайзер активен")
                        .font(SN.text(.caption, .medium))
                        .foregroundStyle(SN.ink)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(SN.card.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Live EQ Frequency Response Curve Visualizer
struct EQResponseCurveView: View {
    let frequencies: [String]
    let gains: [Float]
    let enabled: Bool
    let activeBandIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            if w > 40 && h > 40 {
                let sidePad: CGFloat = 16
                let count = 10
                let stepX = (w - 2 * sidePad) / CGFloat(count - 1)
                let midY = h / 2
                let maxGain: CGFloat = 12.0

                ZStack {
                    Color.black.opacity(0.35)

                    // Reference Grid Lines (+12, 0, -12)
                    Path { path in
                        path.move(to: CGPoint(x: sidePad, y: midY))
                        path.addLine(to: CGPoint(x: w - sidePad, y: midY))
                    }
                    .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    Path { path in
                        path.move(to: CGPoint(x: sidePad, y: midY - (h / 2 - 12)))
                        path.addLine(to: CGPoint(x: w - sidePad, y: midY - (h / 2 - 12)))
                    }
                    .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.8))

                    Path { path in
                        path.move(to: CGPoint(x: sidePad, y: midY + (h / 2 - 12)))
                        path.addLine(to: CGPoint(x: w - sidePad, y: midY + (h / 2 - 12)))
                    }
                    .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 0.8))

                    // Gradient Area Fill under Curve
                    curvePath(w: w, h: h, sidePad: sidePad, stepX: stepX, midY: midY, maxGain: maxGain, isClosed: true)
                        .fill(
                            LinearGradient(
                                colors: [
                                    (enabled ? SN.amber : SN.inkMuted).opacity(enabled ? 0.30 : 0.08),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Curve Stroke
                    curvePath(w: w, h: h, sidePad: sidePad, stepX: stepX, midY: midY, maxGain: maxGain, isClosed: false)
                        .stroke(
                            enabled ? SN.amber : SN.inkMuted.opacity(0.4),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )

                    // Active Node highlights
                    ForEach(0..<count, id: \.self) { i in
                        let x = sidePad + CGFloat(i) * stepX
                        let g = CGFloat(i < gains.count ? gains[i] : 0)
                        let clamped = min(maxGain, max(-maxGain, g))
                        let y = midY - (clamped / maxGain) * (h / 2 - 14)
                        let isActive = (activeBandIndex == i)

                        Circle()
                            .fill(isActive ? SN.amber : Color.white)
                            .frame(width: isActive ? 8 : 4, height: isActive ? 8 : 4)
                            .shadow(color: SN.amber.opacity(isActive ? 0.9 : 0.0), radius: 6)
                            .position(x: x, y: y)
                            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isActive)
                            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: y)
                    }
                }
            }
        }
    }

    private func curvePath(w: CGFloat, h: CGFloat, sidePad: CGFloat, stepX: CGFloat, midY: CGFloat, maxGain: CGFloat, isClosed: Bool) -> Path {
        var points: [CGPoint] = []
        let count = 10
        for i in 0..<count {
            let x = sidePad + CGFloat(i) * stepX
            let g = CGFloat(i < gains.count ? gains[i] : 0)
            let clamped = min(maxGain, max(-maxGain, g))
            let y = midY - (clamped / maxGain) * (h / 2 - 14)
            points.append(CGPoint(x: x, y: y))
        }

        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        for i in 0..<(points.count - 1) {
            let p0 = points[i]
            let p1 = points[i + 1]
            let midX = (p0.x + p1.x) / 2
            path.addCurve(to: p1, control1: CGPoint(x: midX, y: p0.y), control2: CGPoint(x: midX, y: p1.y))
        }

        if isClosed {
            path.addLine(to: CGPoint(x: w - sidePad, y: h))
            path.addLine(to: CGPoint(x: sidePad, y: h))
            path.closeSubpath()
        }

        return path
    }
}

// MARK: - 10-Band Vertical Faders Deck
struct EQFadersDeckView: View {
    let frequencies: [String]
    @Binding var gains: [Float]
    let enabled: Bool
    @Binding var activeBandIndex: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(frequencies.count, 10), id: \.self) { i in
                EQVerticalFader(
                    frequency: frequencies[i],
                    gain: Binding(
                        get: { i < gains.count ? gains[i] : 0 },
                        set: { val in
                            if i < gains.count {
                                gains[i] = val
                            }
                        }
                    ),
                    enabled: enabled,
                    isActive: activeBandIndex == i,
                    onDragStart: { activeBandIndex = i },
                    onDragEnd: {
                        activeBandIndex = nil
                        PlayerCore.shared.saveEQ()
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 200)
    }
}

// MARK: - Single Vertical Fader Column
struct EQVerticalFader: View {
    let frequency: String
    @Binding var gain: Float
    let enabled: Bool
    let isActive: Bool
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    private let maxGain: Float = 12.0
    private let trackHeight: CGFloat = 130

    var body: some View {
        VStack(spacing: 6) {
            // Gain Text Readout
            Text(formatDB(gain))
                .font(.system(size: 10, weight: (isActive || abs(gain) > 0.5) ? .bold : .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(textColor)
                .frame(height: 14)

            // Vertical Track and Thumb
            GeometryReader { geo in
                let h = max(40, geo.size.height)
                let midY = h / 2
                let ratio = CGFloat(gain / maxGain)
                let thumbY = midY - ratio * (h / 2 - 8)

                ZStack {
                    // Track background capsule
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 6)

                    // Center 0 dB Notch
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 12, height: 2)
                        .position(x: geo.size.width / 2, y: midY)

                    // Bipolar Fill bar from center (up or down)
                    if abs(gain) > 0.1 {
                        let fillH = abs(ratio) * (h / 2 - 8)
                        let fillY = ratio > 0 ? (midY - fillH / 2) : (midY + fillH / 2)
                        Capsule()
                            .fill(enabled ? SN.amber : SN.inkMuted)
                            .frame(width: 5, height: fillH)
                            .position(x: geo.size.width / 2, y: fillY)
                    }

                    // Tactile Thumb Pill
                    ZStack {
                        Capsule()
                            .fill(thumbFillColor)
                            .frame(width: 26, height: 16)
                            .shadow(color: Color.black.opacity(0.4), radius: 3, y: 1.5)
                            .overlay(
                                Capsule()
                                    .strokeBorder(isActive ? SN.amber : Color.white.opacity(0.3), lineWidth: 1.2)
                            )

                        // Center grip notch
                        Capsule()
                            .fill(isActive ? Color.black.opacity(0.7) : Color.white.opacity(0.5))
                            .frame(width: 10, height: 2)
                    }
                    .position(x: geo.size.width / 2, y: thumbY)
                    .scaleEffect(isActive ? 1.15 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isActive)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { val in
                            guard enabled else { return }
                            onDragStart()
                            let deltaY = midY - val.location.y
                            let raw = Float((deltaY / (h / 2 - 8)) * CGFloat(maxGain))
                            guard raw.isFinite else { return }
                            let clamped = min(maxGain, max(-maxGain, raw))
                            // Snap to 0 when near center
                            let newGain: Float = abs(clamped) < 0.6 ? 0.0 : round(clamped)

                            if gain != newGain {
                                if (gain > 0 && newGain <= 0) || (gain < 0 && newGain >= 0) {
                                    Haptics.tap(.light)
                                }
                                gain = newGain
                            }
                        }
                        .onEnded { _ in
                            onDragEnd()
                        }
                )
            }
            .frame(height: trackHeight)

            // Frequency Label Badge
            Text(frequency)
                .font(.system(size: 10, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundStyle(isActive ? SN.amber : SN.inkMuted)
                .frame(height: 14)
        }
    }

    private var textColor: Color {
        guard enabled else { return SN.inkMuted.opacity(0.4) }
        if isActive { return SN.amber }
        if abs(gain) > 0.5 { return SN.ink }
        return SN.inkMuted
    }

    private var thumbFillColor: Color {
        guard enabled else { return SN.card }
        if isActive { return SN.amber }
        return Color(white: 0.95)
    }

    private func formatDB(_ value: Float) -> String {
        let rounded = Int(round(value))
        if rounded > 0 { return "+\(rounded)" }
        return "\(rounded)"
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
