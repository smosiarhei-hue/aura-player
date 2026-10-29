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
    @State private var userPresets = EQUserPresetStore()
    @State private var showingSavePreset = false
    @State private var presetName = ""
    @State private var presetError: String?
    @State private var deletingPreset: SavedEQPreset?
    @State private var selectedBand = 0
    @State private var isAdjustingEQ = false
    @State private var adjustmentFeedback = EQAdjustmentFeedback()
    @Environment(\.accessibilityReduceMotion) private var reduceEQMotion

    private let bandNames = EQFrequencyRegion.bandTitles
    private let frequencyLabels = EQGainLimits.frequencies.map { "\(Int($0)) Гц" }
    private var primaryPresets: [EQPreset] { [EQPresets.flat, EQPresets.airPodsPro2Bass, EQPresets.bassBoost, EQPresets.subBassPower, EQPresets.bassTrebleBoost] }
    private var activePreset: EQPreset? { EQPresets.all.first { matches($0.gains) } }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    masterCard
                    bandsSection
                    profilesSection
                    savedPresetsSection
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
        .alert("Сохранить пресет", isPresented: $showingSavePreset) {
            TextField("Название", text: $presetName)
            Button("Отмена", role: .cancel) { }
            Button("Сохранить") {
                do {
                    try userPresets.save(name: presetName, gains: PlayerCore.normalized(player.eqGains))
                    player.saveEQ()
                } catch { presetError = error.localizedDescription }
            }
        } message: {
            Text("Сохраняются значения всех шести полос. Системная громкость не меняется.")
        }
        .alert("Не удалось сохранить", isPresented: Binding(
            get: { presetError != nil }, set: { if !$0 { presetError = nil } }
        )) {
            Button("ОК", role: .cancel) { presetError = nil }
        } message: { Text(presetError ?? "") }
        .confirmationDialog("Удалить пресет?", isPresented: Binding(
            get: { deletingPreset != nil }, set: { if !$0 { deletingPreset = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let preset = deletingPreset {
                    do { try userPresets.delete(id: preset.id) }
                    catch { presetError = error.localizedDescription }
                }
                deletingPreset = nil
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
                    Text(player.eqEnabled ? (activePreset?.name ?? userPresets.presets.first(where: { matches($0.gains) })?.name ?? "Своя настройка") : "Исходный звук")
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
                 : "Профили меняют баланс частот, не системную громкость. Начни с небольшого усиления: так сохраняется больше динамики.")
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
                Text("±15 дБ").font(.subheadline.monospacedDigit()).foregroundStyle(SN.inkMuted)
            }
            Text("6 полос · низкие, средние и высокие частоты")
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
            Text("Без постоянного снижения громкости. Плавные фильтры и защита пиков; сильное усиление может уменьшать динамику.")
                .font(.caption).foregroundStyle(SN.inkMuted)
            if player.eqGains.contains(where: { $0 >= 8 }) {
                Label("Большое усиление может сжимать динамику. Для более чистого звука попробуй +3…+6 дБ.", systemImage: "waveform.path.badge.minus")
                    .font(.caption).foregroundStyle(SN.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Диапазон частот", selection: Binding(
                get: { EQFrequencyRegion.containing(selectedBand) },
                set: { selectedBand = $0.indices.lowerBound }
            )) {
                ForEach(EQFrequencyRegion.allCases) { region in
                    Text(region.title).tag(region)
                }
            }
            .pickerStyle(.segmented)
            Text(EQFrequencyRegion.containing(selectedBand).detail)
                .font(.subheadline).foregroundStyle(SN.inkMuted)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        ForEach(PlayerCore.bandFrequencies.indices, id: \.self) { index in
                            bandRow(index)
                            if index < PlayerCore.bandFrequencies.count - 1 { Divider().padding(.horizontal, 16) }
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        CompactEQCurve(gains: player.eqGains, selectedBand: $selectedBand, isInteracting: isAdjustingEQ,
                                       onChange: { setBandGain($0, $1) }, onReset: { setBandGain($0, 0, feedback: false) }, onEnd: { player.saveEQ() })
                            .frame(height: 240)
                            .accessibilityHidden(true)
                        Text("Двойной тап по точке — 0 дБ")
                            .font(.caption).foregroundStyle(SN.inkMuted)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: EQGainLimits.frequencies.count), spacing: 4) {
                            ForEach(PlayerCore.bandFrequencies.indices, id: \.self) { index in
                                Button { selectedBand = index } label: {
                                    Text(compactFrequency(index) + (PlayerCore.bandFrequencies[index] >= 1000 ? "Гц" : " Гц"))
                                        .font(.caption2.weight(.semibold)).monospacedDigit()
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(selectedBand == index ? SN.amber.opacity(0.16) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Выбрать \(frequencyLabels[index])")
                                .accessibilityValue(db(player.eqGains.indices.contains(index) ? player.eqGains[index] : 0))
                                .accessibilityAddTraits(selectedBand == index ? .isSelected : [])
                            }
                        }
                        bandRow(selectedBand)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Суммарная АЧХ · модель PCM 48 кГц")
                                .font(.caption).foregroundStyle(SN.inkMuted)
                            EQFrequencyResponseShape(vector: EQCurveVector(player.eqGains))
                                .stroke(SN.amber.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .background(alignment: .center) { Rectangle().fill(SN.ink.opacity(0.12)).frame(height: 1) }
                                .frame(height: 88)
                                .animation(reduceEQMotion || isAdjustingEQ ? nil : .smooth(duration: 0.24), value: player.eqGains)
                                .accessibilityHidden(true)
                            HStack { Text("20 Гц"); Spacer(); Text("±36 дБ"); Spacer(); Text("20 кГц") }
                                .font(.caption2.monospacedDigit()).foregroundStyle(SN.inkMuted)
                            Text("Сумма фильтров до защиты пиков, не измерение наушников.")
                                .font(.caption2).foregroundStyle(SN.inkMuted)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                    .padding(12)
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

    private func compactFrequency(_ index: Int) -> String {
        let frequency = PlayerCore.bandFrequencies[index]
        if frequency < 1000 { return "\(Int(frequency))" }
        return frequency.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(frequency / 1000))к" : String(format: "%.1fк", frequency / 1000).replacingOccurrences(of: ".", with: ",")
    }

    private func setBandGain(_ index: Int, _ gain: Float, feedback: Bool = true) {
        guard PlayerCore.bandFrequencies.indices.contains(index) else { return }
        var curve = PlayerCore.normalized(player.eqGains)
        let oldGain = curve[index]
        curve[index] = EQGainLimits.clean((gain * 2).rounded() / 2, at: index)
        player.eqGains = curve
        if feedback, let strength = adjustmentFeedback.intensity(from: oldGain, to: curve[index], at: ProcessInfo.processInfo.systemUptime) {
            Haptics.eqAdjustment(intensity: strength)
        }
    }

    private var savedPresetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Мои пресеты").font(.headline).foregroundStyle(SN.ink)
            Button {
                presetName = ""
                showingSavePreset = true
            } label: {
                Label("Сохранить текущую настройку", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if userPresets.presets.isEmpty {
                Text("Сохрани свой баланс частот, чтобы вернуть его одним нажатием.")
                    .font(.subheadline).foregroundStyle(SN.inkMuted)
            }
            ForEach(userPresets.presets) { preset in
                HStack(spacing: 12) {
                    Button {
                        player.eqGains = preset.gains
                        player.eqEnabled = true
                        player.saveEQ()
                    } label: {
                        HStack {
                            Text(preset.name).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if matches(preset.gains) { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityAddTraits(matches(preset.gains) ? .isSelected : [])
                    Button { deletingPreset = preset } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Удалить пресет \(preset.name)")
                }
            }
        }
        .padding(16)
        .background(SN.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private func bandRow(_ index: Int) -> some View {
        let gain = player.eqGains.indices.contains(index) ? player.eqGains[index] : 0
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
                get: { Double(player.eqGains.indices.contains(index) ? player.eqGains[index] : 0) },
                set: { value in
                    setBandGain(index, Float(value))
                }
            ), in: Double(EQGainLimits.range(at:index).lowerBound)...Double(EQGainLimits.range(at:index).upperBound), step: 0.5, onEditingChanged: { editing in
                isAdjustingEQ = editing
                if !editing { player.saveEQ() }
            })
            .tint(SN.amber)
            .frame(minHeight: 44)
            .accessibilityLabel("\(bandNames[index]), \(frequencyLabels[index])")
            .accessibilityValue(db(gain))
            HStack {
                Text("−15")
                Spacer()
                Button("0 дБ") {
                    var curve = PlayerCore.normalized(player.eqGains)
                    curve[index] = 0
                    player.eqGains = curve
                    player.saveEQ()
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Сбросить \(frequencyLabels[index])")
                Spacer()
                Text("+\(Int(EQGainLimits.range(at:index).upperBound))")
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
            Text("Для AirPods Pro 2 проверь прилегание амбушюр в настройках iPhone. Нижняя полка 60 Гц воздействует и на частоты ниже неё. Полосы 150 и 400 Гц помогают настроить удар и плотность. Точная нижняя граница не заявлена Apple.")
            Text("16 кГц — номинальная верхняя полоса. Саб 60 Гц качает драйверы; удар 120 Гц — отдельно. Рабочая частота ограничена частотой дискретизации аудиовыхода.")
            Text("Постоянного ослабления общей громкости нет. Защита пиков работает при ненулевой кривой EQ и может кратковременно снижать уровень при перегрузке. Flat и выключенный EQ сохраняют исходный сигнал. EQ не исправляет искажения записи или наушников.")
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
        return "\(PlayerCore.bandFrequencies.count) полос • обработка в реальном времени"
    }
    private func applyPreset(_ preset: EQPreset) {
        player.eqGains = preset.gains
        player.eqEnabled = true
        player.saveEQ()
        Haptics.tap(.light)
    }
    private func matches(_ gains: [Float]) -> Bool {
        guard gains.count == PlayerCore.bandFrequencies.count else { return false }
        return zip(PlayerCore.normalized(player.eqGains), gains).allSatisfy { abs($0 - $1) < 0.2 }
    }
    private func db(_ gain: Float) -> String { String(format: "%+.1f дБ", gain) }
    private func presetIcon(_ preset: EQPreset) -> String {
        if preset == EQPresets.airPodsPro2Bass { return "earbuds" }
        if preset == EQPresets.flat { return "slider.horizontal.3" }
        return "waveform"
    }
}

/// Control-gain curve, not a measured summed DSP response. Every node maps to one real band.
private struct CompactEQCurve: View {
    let gains: [Float]
    @Binding var selectedBand: Int
    var isInteracting: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onChange: (Int, Float) -> Void
    let onReset: (Int) -> Void
    let onEnd: () -> Void
    @State private var draggingBand: Int?

    private func point(_ index: Int, size: CGSize) -> CGPoint {
        let gain = EQGainLimits.clean(gains.indices.contains(index) ? gains[index] : 0, at: index)
        return CGPoint(x: EQGainLimits.graphX(at: index, width: Double(size.width)),
                       y: EQGainLimits.graphY(gain: gain, height: Double(size.height)))
    }
    private func hitBand(_ location: CGPoint, size: CGSize) -> Int? {
        EQGainLimits.graphHitBand(x: Double(location.x), y: Double(location.y),
                                 width: Double(size.width), height: Double(size.height), gains: gains)
    }
    private func resetPoint(at location: CGPoint, size: CGSize) {
        guard let index = hitBand(location, size: size) else { return }
        selectedBand = index
        onReset(index)
        onEnd()
        Haptics.tap(.light)
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Path { path in
                    let zeroY = EQGainLimits.graphY(gain: 0, height: Double(size.height))
                    path.move(to: CGPoint(x: 14, y: zeroY))
                    path.addLine(to: CGPoint(x: size.width - 14, y: zeroY))
                }
                .stroke(SN.ink.opacity(0.15), lineWidth: 1)
                EQControlCurveShape(vector: EQCurveVector(gains))
                    .stroke(LinearGradient(colors: [SN.amber, SN.amber.opacity(0.7), SN.amber],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                ForEach(EQGainLimits.frequencies.indices, id: \.self) { index in
                    Circle().fill(SN.card)
                        .overlay(Circle().stroke(SN.amber, lineWidth: index == selectedBand ? 3 : 2))
                        .frame(width: index == selectedBand ? 18 : 12, height: index == selectedBand ? 18 : 12)
                        .position(point(index, size: size))
                        .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: selectedBand)
                }
            }
            .contentShape(Rectangle())
            // Double tap wins over dragging. A small drag threshold prevents
            // either tap from moving the gain before the reset is recognized.
            .gesture(SpatialTapGesture(count: 2)
                .onEnded { value in resetPoint(at: value.location, size: size) }
                .exclusively(before: DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if draggingBand == nil {
                        guard let closest = hitBand(value.startLocation, size: size) else { return }
                        draggingBand = closest
                        selectedBand = closest
                    }
                    guard let index = draggingBand else { return }
                    let rawGain = EQGainLimits.graphGain(y: Double(value.location.y), height: Double(size.height), at: index)
                    onChange(index, rawGain)
                }
                .onEnded { _ in
                    if draggingBand != nil { onEnd() }
                    draggingBand = nil
                }))
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { value in
                if let index = hitBand(value.location, size: size) { selectedBand = index }
            })
        }
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
