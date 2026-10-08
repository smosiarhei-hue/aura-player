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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedRegion = EQRegion.bass

    private enum EQRegion: String, CaseIterable, Identifiable {
        case bass = "Низ", mids = "Середина", treble = "Верх"
        var id: String { rawValue }
        var indices: [Int] {
            switch self {
            case .bass: return [0, 1, 2]
            case .mids: return [3, 4, 5, 6]
            case .treble: return [7, 8, 9]
            }
        }
        var detail: String {
            switch self {
            case .bass: return "Глубина, удар и вес баса"
            case .mids: return "Тело инструментов и разборчивость голоса"
            case .treble: return "Детали, яркость и воздух"
            }
        }
    }

    private let bandNames = ["Глубина", "Удар бочки", "Плотность", "Теплота", "Тело", "Голос", "Присутствие", "Детали", "Яркость", "Воздух"]
    private let frequencyLabels = ["31,25 Гц · нижняя полка", "62,5 Гц", "125 Гц", "250 Гц", "500 Гц", "1 кГц", "2 кГц", "4 кГц", "8 кГц", "16 кГц · верхняя полка"]
    private var primaryPresets: [EQPreset] { [EQPresets.flat, EQPresets.airPodsPro2Bass, EQPresets.bassBoost, EQPresets.bassTrebleBoost] }
    private var activePreset: EQPreset? { EQPresets.all.first { matches($0.gains) } }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    masterCard
                    profilesSection
                    bandsSection
                    outputCard
                    listeningNote
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(SN.bg)
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сбросить") { applyPreset(EQPresets.flat) }
                        .disabled(matches(EQPresets.flat.gains))
                        .accessibilityHint("Вернуть все полосы к нулю, не меняя громкость телефона")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { player.saveEQ(); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(SN.bg)
    }

    private var masterCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $player.eqEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Твой звук")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(SN.ink)
                    Text(player.eqEnabled ? (activePreset?.name ?? "Своя настройка") : "Исходный звук")
                        .font(.subheadline)
                        .foregroundStyle(SN.inkMuted)
                }
            }
            .tint(SN.amber)
            .accessibilityLabel("Эквалайзер")
            Label(eqStatusText, systemImage: player.isEQEffectivelyActive ? "checkmark.circle" : "info.circle")
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(SN.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Выбери характер")
                .font(.headline)
                .foregroundStyle(SN.ink)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(primaryPresets) { preset in presetButton(preset) }
            }
            DisclosureGroup("Ещё профили") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach([EQPresets.classical, EQPresets.club, EQPresets.dance]) { preset in presetButton(preset) }
                }
                .padding(.top, 12)
            }
            .font(.subheadline)
            .foregroundStyle(SN.inkMuted)
            .tint(SN.ink)
            Text(activePreset?.name == EQPresets.airPodsPro2Bass.name
                 ? "AirPods Pro 2: мягкий глубокий низ без лишнего гула. Это профиль приложения, не калибровка Apple."
                 : "Профили меняют частотный баланс, а не громкость iPhone.")
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetButton(_ preset: EQPreset) -> some View {
        let selected = matches(preset.gains)
        return Button { applyPreset(preset) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: presetIcon(preset))
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                }
                .font(.body.weight(.semibold))
                Text(preset.name).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(SN.ink)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .background(selected ? SN.amber.opacity(0.12) : SN.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(selected ? SN.ink : SN.ink.opacity(0.15), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(EQProfilePressStyle())
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var bandsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Точная настройка").font(.headline)
                Spacer()
                Text("±12 дБ").font(.subheadline.monospacedDigit()).foregroundStyle(SN.inkMuted)
            }
            Picker("Диапазон частот", selection: $selectedRegion) {
                ForEach(EQRegion.allCases) { region in Text(region.rawValue).tag(region) }
            }
            .pickerStyle(.segmented)
            Text(selectedRegion.detail)
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
            VStack(spacing: 0) {
                ForEach(selectedRegion.indices, id: \.self) { index in
                    bandRow(index)
                    if index != selectedRegion.indices.last { Divider().padding(.horizontal, 16) }
                }
            }
            .background(SN.card, in: RoundedRectangle(cornerRadius: 24))
            .disabled(!player.eqEnabled)
            .opacity(player.eqEnabled ? 1 : 0.55)
            if !player.eqEnabled {
                Text("Включи EQ, чтобы изменить полосы. Сохранённая настройка не сбрасывается.")
                    .font(.subheadline).foregroundStyle(SN.inkMuted)
            }
        }
        .foregroundStyle(SN.ink)
    }

    private func bandRow(_ index: Int) -> some View {
        let gain = PlayerCore.normalized(player.eqGains)[index]
        return VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    bandTitle(index)
                    Spacer(minLength: 16)
                    Text(db(gain)).font(.headline.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 8) {
                    bandTitle(index)
                    Text(db(gain)).font(.headline.monospacedDigit())
                }
            }
            Slider(value: Binding(
                get: { Double(PlayerCore.normalized(player.eqGains)[index]) },
                set: { value in
                    var curve = PlayerCore.normalized(player.eqGains)
                    curve[index] = Float(value)
                    player.eqGains = curve
                }
            ), in: -12...12, step: 0.5, onEditingChanged: { editing in
                if !editing { player.saveEQ() }
            })
            .tint(SN.amber)
            .frame(minHeight: 44)
            .accessibilityLabel("\(bandNames[index]), \(frequencyLabels[index])")
            .accessibilityValue(db(gain))
            HStack {
                Text("−12")
                Spacer()
                Button("0 дБ") {
                    var curve = PlayerCore.normalized(player.eqGains)
                    curve[index] = 0
                    player.eqGains = curve
                    player.saveEQ()
                }
                .frame(minWidth: 60, minHeight: 44)
                .accessibilityLabel("Сбросить \(bandNames[index])")
                Spacer()
                Text("+12")
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(SN.inkMuted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func bandTitle(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bandNames[index]).font(.headline)
            Text(frequencyLabels[index]).font(.subheadline).foregroundStyle(SN.inkMuted)
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Только в наушниках", isOn: $player.eqHeadphonesOnly)
                .font(.body.weight(.medium))
                .tint(SN.amber)
            Text(outputStatusText)
                .font(.subheadline).foregroundStyle(SN.inkMuted)
            Text("В этом режиме динамик телефона остаётся без усиления баса.")
                .font(.subheadline).foregroundStyle(SN.inkMuted)
        }
        .foregroundStyle(SN.ink)
        .padding(20)
        .background(SN.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private var outputStatusText: String {
        if !player.eqEnabled { return player.isHeadphonesConnected ? "Наушники • исходный звук" : "Динамик телефона • исходный звук" }
        if player.eqHeadphonesOnly && !player.isHeadphonesConnected { return "Динамик телефона • режим Flat" }
        if let reason = player.eqUnavailableReason { return reason }
        if player.isEQPreparingNativeStream { return "Ожидание воспроизводимого аудио" }
        return player.isHeadphonesConnected ? "Наушники • EQ в реальном времени" : "EQ • обработка воспроизводимого звука"
    }

    private var listeningNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Бас начинается с посадки", systemImage: "earbuds")
                .font(.subheadline.weight(.semibold))
            Text("Для AirPods Pro 2 проверь прилегание амбушюр в настройках iPhone. Нижняя полка 31,25 Гц воздействует и на частоты ниже неё; 62,5 Гц отвечает за удар, 125 Гц — за плотность. Точная нижняя граница не заявлена Apple.")
            Text("Защита EQ от перегрузки отключена. Сильное усиление может вызвать хрип и искажения. EQ не добавляет низкие частоты, которых нет в записи. Проверяй настройки сначала на небольшой громкости.")
        }
        .font(.subheadline)
        .foregroundStyle(SN.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var eqStatusText: String {
        if !player.eqEnabled { return "Выключен • исходный звук" }
        if player.eqHeadphonesOnly && !player.isHeadphonesConnected { return "Приостановлен для динамика телефона" }
        if let reason = player.eqUnavailableReason { return reason }
        if player.isEQPreparingNativeStream { return "Ожидание воспроизводимого аудио" }
        return "10 полос • обработка в реальном времени"
    }
    private func applyPreset(_ preset: EQPreset) {
        player.eqGains = preset.gains
        player.eqEnabled = true
        player.saveEQ()
        Haptics.tap(.light)
    }
    private func matches(_ gains: [Float]) -> Bool {
        zip(PlayerCore.normalized(player.eqGains), gains).allSatisfy { abs($0 - $1) < 0.2 }
    }
    private func db(_ gain: Float) -> String { String(format: "%+.1f дБ", gain) }
    private func presetIcon(_ preset: EQPreset) -> String {
        if preset == EQPresets.airPodsPro2Bass { return "earbuds" }
        if preset == EQPresets.flat { return "slider.horizontal.3" }
        return "waveform"
    }
}

private struct EQProfilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
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
