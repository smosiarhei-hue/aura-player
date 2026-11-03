// Path: Sonivo/PlayerEQSheetView.swift
import Observation
import SwiftUI

/// Sonivo EQ — "studio console" layout.
/// Power → direct-manipulation curve → compact presets → output.
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
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceEQMotion

    private let bandNames = EQFrequencyRegion.bandTitles
    private let frequencyLabels = EQGainLimits.frequencies.indices.map { index in
        let hz = EQGainLimits.frequencies[index]
        return hz < 1000 ? "\(Int(hz)) Гц" : "\(Int(hz / 1000)) кГц"
    }
    /// Flat → Bass → Deep bass → Bass+Treble → Classical → Club → Dance
    private var primaryPresets: [EQPreset] {
        [EQPresets.flat, EQPresets.bassBoost, EQPresets.subBassPower, EQPresets.bassTrebleBoost,
         EQPresets.classical, EQPresets.club, EQPresets.dance]
    }
    /// Generic earphone taste — not a device calibration.
    private var secondaryPresets: [EQPreset] { [EQPresets.airPodsPro2Bass] }
    private var activePreset: EQPreset? { EQPresets.all.first { matches($0.gains) } }
    private var activeCurveName: String {
        activePreset?.name ?? userPresets.presets.first(where: { matches($0.gains) })?.name ?? "Своя кривая"
    }
    private var selectedGain: Float {
        player.eqGains.indices.contains(selectedBand) ? player.eqGains[selectedBand] : 0
    }
    private var trimmedPresetName: String { presetName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    masterHeader
                        .eqReveal(appeared: appeared, reduceMotion: reduceEQMotion, delay: 0)
                    console
                        .eqReveal(appeared: appeared, reduceMotion: reduceEQMotion, delay: 0.04)
                    profilesSection
                        .eqReveal(appeared: appeared, reduceMotion: reduceEQMotion, delay: 0.12)
                    savedPresetsSection
                        .eqReveal(appeared: appeared, reduceMotion: reduceEQMotion, delay: 0.16)
                    outputCard
                        .eqReveal(appeared: appeared, reduceMotion: reduceEQMotion, delay: 0.20)
                    listeningNote
                        .eqReveal(appeared: appeared, reduceMotion: reduceEQMotion, delay: 0.24)
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background {
                ZStack {
                    SN.bg
                    RadialGradient(
                        colors: [SN.amber.opacity(player.eqEnabled ? 0.16 : 0.04), .clear],
                        center: UnitPoint(x: 0.5, y: 0.18), startRadius: 8, endRadius: 420
                    )
                    .animation(reduceEQMotion ? nil : SN.slowSpring, value: player.eqEnabled)
                }
                .ignoresSafeArea()
            }
            .navigationTitle("Эквалайзер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сбросить") { resetCurve() }
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
                    try userPresets.save(name: trimmedPresetName, gains: PlayerCore.normalized(player.eqGains))
                    player.saveEQ()
                    Haptics.success()
                } catch { presetError = error.localizedDescription }
            }
            .disabled(trimmedPresetName.isEmpty)
        } message: {
            Text("Сохраняются значения всех десяти полос. Системная громкость не меняется.")
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
        .onAppear {
            guard !reduceEQMotion else { appeared = true; return }
            withAnimation(SN.spring) { appeared = true }
        }
    }

    // MARK: Power header

    private var masterHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { toggleEQ() } label: {
                ZStack {
                    Circle()
                        .fill(player.eqEnabled ? SN.amber : SN.card)
                    Image(systemName: "power")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(player.eqEnabled ? SN.onAccent : SN.inkMuted)
                        .symbolEffect(.bounce, value: player.eqEnabled)
                }
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(SN.ink.opacity(player.eqEnabled ? 0 : 0.12), lineWidth: 1))
                .shadow(color: SN.amber.opacity(player.eqEnabled ? 0.20 : 0), radius: 8, y: 2)
                .contentShape(Circle())
            }
            .buttonStyle(EQProfilePressStyle())
            .accessibilityLabel("Эквалайзер")
            .accessibilityValue(player.eqEnabled ? "Включён" : "Выключен")
            .accessibilityAddTraits(.isToggle)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.eqEnabled ? activeCurveName : "Выключен")
                    .font(.headline)
                    .foregroundStyle(SN.ink)
                    .contentTransition(.numericText())
                    .lineLimit(2)
                Label {
                    Text(eqStatusText)
                } icon: {
                    Image(systemName: player.isEQEffectivelyActive ? "waveform" : "minus.circle")
                        .symbolEffect(.variableColor.iterative, isActive: player.isEQEffectivelyActive && !reduceEQMotion)
                }
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Console (hero)

    /// Lanes, response, curve and nodes share one GeometryReader, so the fill
    /// always sits exactly under the points and labels line up with the lanes.
    private var console: some View {
        VStack(alignment: .leading, spacing: 10) {
            consoleHUD
            CompactEQCurve(
                gains: player.eqGains,
                selectedBand: $selectedBand,
                isInteracting: isAdjustingEQ,
                isEnabled: player.eqEnabled,
                onChange: { index, gain in
                    isAdjustingEQ = true
                    setBandGain(index, gain)
                },
                onReset: { index in
                    setBandGain(index, 0, feedback: false)
                },
                onEnd: {
                    isAdjustingEQ = false
                    player.saveEQ()
                },
                onStep: { index, delta in
                    nudge(index, by: delta)
                }
            )
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 220)
            .opacity(player.eqEnabled ? 1 : 0.38)
            .disabled(!player.eqEnabled)
            .overlay {
                if !player.eqEnabled {
                    Button { toggleEQ() } label: {
                        Label("Включить эквалайзер", systemImage: "power")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SN.ink)
                    .glassCapsule(interactive: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Кривая эквалайзера")
            .accessibilityHint("Перетащи полосу вверх или вниз. Двойной тап — 0 дБ.")

            Text("Тяни точку или частоту вверх/вниз · двойное касание — 0 дБ")
                .font(.caption)
                .foregroundStyle(SN.inkMuted)

            Text("Пунктир — суммарная АЧХ · модель PCM 48 кГц · не измерение наушников")
                .font(.caption)
                .foregroundStyle(SN.inkFaint)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: SN.radiusLarge, style: .continuous)
                .fill(SN.card.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SN.radiusLarge, style: .continuous)
                .strokeBorder(SN.ink.opacity(0.08), lineWidth: 1)
        )
    }

    private var consoleHUD: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bandNames[selectedBand])
                        .font(.headline)
                        .foregroundStyle(SN.ink)
                    Text(frequencyLabels[selectedBand])
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(SN.inkMuted)
                }
                Spacer(minLength: 12)
                gainReadout
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(bandNames[selectedBand]) · \(frequencyLabels[selectedBand])")
                    .font(.headline)
                gainReadout
            }
        }
        .animation(reduceEQMotion || isAdjustingEQ ? nil : SN.fastSpring, value: selectedBand)
    }

    private var gainReadout: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(String(format: "%+.1f", selectedGain))
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(selectedGain == 0 ? SN.ink : SN.amber)
                .contentTransition(.numericText(value: Double(selectedGain)))
                .animation(reduceEQMotion || isAdjustingEQ ? nil : SN.fastSpring, value: selectedGain)
            Text("дБ")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SN.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Presets

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пресеты").font(.headline).foregroundStyle(SN.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(primaryPresets) { preset in presetChip(preset) }
                    ForEach(secondaryPresets) { preset in presetChip(preset) }
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            Text("Только полосные фильтры — без сжатия микса и без peak duck. Начни с +2…+4 дБ.")
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetChip(_ preset: EQPreset) -> some View {
        let selected = player.eqEnabled && matches(preset.gains)
        return Button { applyPreset(preset) } label: {
            VStack(alignment: .leading, spacing: 8) {
                EQMiniCurve(gains: preset.gains)
                    .stroke(selected ? SN.onAccent : SN.amber,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 22)
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Image(systemName: presetIcon(preset))
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(preset.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? SN.onAccent : SN.ink)
            .padding(10)
            .frame(width: 112)
            .frame(minHeight: 70, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SN.radius, style: .continuous)
                    .fill(selected ? SN.amber : SN.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SN.radius, style: .continuous)
                    .strokeBorder(SN.ink.opacity(selected ? 0 : 0.10), lineWidth: 1)
            )
            .shadow(color: SN.amber.opacity(selected ? 0.16 : 0), radius: 6, y: 2)
            .scaleEffect(selected && !reduceEQMotion ? 1.02 : 1)
            .animation(reduceEQMotion ? nil : SN.fastSpring, value: selected)
        }
        .buttonStyle(EQProfilePressStyle())
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var savedPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Мои пресеты").font(.headline).foregroundStyle(SN.ink)
                Spacer()
                Button {
                    presetName = ""
                    showingSavePreset = true
                } label: {
                    Label("Сохранить", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SN.ink)
                .glassCapsule(interactive: true)
                .accessibilityLabel("Сохранить текущую настройку")
            }
            if userPresets.presets.isEmpty {
                Text("Сохрани свой баланс частот, чтобы вернуть его одним нажатием.")
                    .font(.subheadline).foregroundStyle(SN.inkMuted)
            }
            ForEach(userPresets.presets) { preset in
                let selected = matches(preset.gains)
                HStack(spacing: 12) {
                    Button {
                        withAnimation(reduceEQMotion ? nil : SN.fastSpring) {
                            player.eqGains = preset.gains
                            player.eqEnabled = true
                        }
                        player.saveEQ()
                        Haptics.tap(.light)
                    } label: {
                        HStack(spacing: 12) {
                            EQMiniCurve(gains: preset.gains)
                                .stroke(SN.amber, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .frame(width: 56, height: 24)
                                .accessibilityHidden(true)
                            Text(preset.name)
                                .foregroundStyle(SN.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(SN.amber)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    Button { deletingPreset = preset } label: {
                        Image(systemName: "trash").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SN.inkMuted)
                    .accessibilityLabel("Удалить пресет \(preset.name)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: SN.radiusSmall, style: .continuous)
                        .fill(SN.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SN.radiusSmall, style: .continuous)
                        .strokeBorder(selected ? SN.amber.opacity(0.6) : SN.ink.opacity(0.08), lineWidth: 1)
                )
                .contextMenu {
                    Button("Удалить", systemImage: "trash", role: .destructive) { deletingPreset = preset }
                }
            }
        }
    }

    // MARK: Output

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $player.eqHeadphonesOnly.animation(reduceEQMotion ? nil : SN.fastSpring)) {
                Label("Только в наушниках", systemImage: "headphones")
                    .font(.body.weight(.medium))
            }
            .tint(SN.amber)
            HStack(spacing: 8) {
                Circle()
                    .fill(player.isEQEffectivelyActive ? SN.positive : SN.inkFaint)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(outputStatusText)
            }
            .font(.subheadline).foregroundStyle(SN.inkMuted)
            Text("В этом режиме динамик телефона остаётся без усиления баса.")
                .font(.footnote).foregroundStyle(SN.inkFaint)
        }
        .foregroundStyle(SN.ink)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: SN.radius, style: .continuous).fill(SN.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SN.radius, style: .continuous)
                .strokeBorder(SN.ink.opacity(0.08), lineWidth: 1)
        )
    }

    private var outputStatusText: String {
        if !player.eqEnabled { return player.isHeadphonesConnected ? "Наушники • исходный звук" : "Динамик телефона • исходный звук" }
        if player.eqHeadphonesOnly && !player.isHeadphonesConnected { return "Динамик телефона • режим Flat" }
        if let reason = player.eqUnavailableReason { return reason }
        if player.isEQPreparingNativeStream { return "Ожидание воспроизводимого аудио" }
        return player.isHeadphonesConnected ? "Наушники • EQ в реальном времени" : "EQ • обработка воспроизводимого звука"
    }

    private var listeningNote: some View {
        Label {
            Text("Сильный подъём частот может вызвать искажения — начни с умеренной громкости.")
        } icon: {
            Image(systemName: "slider.vertical.3")
        }
        .font(.footnote)
        .foregroundStyle(SN.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var eqStatusText: String {
        if !player.eqEnabled { return "Исходный звук без обработки" }
        if player.eqHeadphonesOnly && !player.isHeadphonesConnected { return "Приостановлен для динамика телефона" }
        if let reason = player.eqUnavailableReason { return reason }
        if player.isEQPreparingNativeStream { return "Ожидание воспроизводимого аудио" }
        return "\(PlayerCore.bandFrequencies.count) полос · 32 Гц–16 кГц"
    }

    // MARK: Actions

    private func setBandGain(_ index: Int, _ gain: Float, feedback: Bool = true) {
        guard PlayerCore.bandFrequencies.indices.contains(index) else { return }
        var curve = PlayerCore.normalized(player.eqGains)
        let oldGain = curve[index]
        curve[index] = EQGainLimits.clean((gain * 2).rounded() / 2, at: index)
        guard curve[index] != oldGain else { return }
        player.eqGains = curve
        if feedback, let strength = adjustmentFeedback.intensity(from: oldGain, to: curve[index], at: ProcessInfo.processInfo.systemUptime) {
            Haptics.eqAdjustment(intensity: strength)
        }
    }

    private func nudge(_ index: Int, by delta: Float) {
        guard PlayerCore.bandFrequencies.indices.contains(index) else { return }
        selectedBand = index
        let current = player.eqGains.indices.contains(index) ? player.eqGains[index] : 0
        setBandGain(index, current + delta, feedback: false)
        player.saveEQ()
        Haptics.tap(.light)
    }

    private func toggleEQ() {
        withAnimation(reduceEQMotion ? nil : SN.fastSpring) { player.eqEnabled.toggle() }
        player.saveEQ()
        Haptics.tap(.medium)
    }

    /// Reset only moves the bands to 0 дБ — it never flips the power state.
    private func resetCurve() {
        withAnimation(reduceEQMotion ? nil : SN.spring) {
            player.eqGains = EQPresets.flat.gains
        }
        player.saveEQ()
        Haptics.tap(.light)
    }

    private func applyPreset(_ preset: EQPreset) {
        withAnimation(reduceEQMotion ? nil : SN.spring) {
            player.eqGains = preset.gains
            player.eqEnabled = true
        }
        player.saveEQ()
        Haptics.tap(.light)
    }
    private func matches(_ gains: [Float]) -> Bool {
        guard gains.count == PlayerCore.bandFrequencies.count else { return false }
        return zip(PlayerCore.normalized(player.eqGains), gains).allSatisfy { abs($0 - $1) < 0.2 }
    }
    private func presetIcon(_ preset: EQPreset) -> String {
        if preset == EQPresets.airPodsPro2Bass { return "earbuds" }
        if preset == EQPresets.flat { return "slider.horizontal.3" }
        if preset == EQPresets.bassBoost || preset == EQPresets.subBassPower { return "speaker.wave.3" }
        if preset == EQPresets.classical { return "music.note" }
        if preset == EQPresets.club || preset == EQPresets.dance { return "music.quarternote.3" }
        return "waveform"
    }
}

/// Interactive console: vertical lane per band, aligned response fill, curve and
/// compact nodes. Drag a lane directly, without a separate slider; double-tap → 0 дБ.
private struct CompactEQCurve: View {
    let gains: [Float]
    @Binding var selectedBand: Int
    var isInteracting: Bool = false
    var isEnabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onChange: (Int, Float) -> Void
    let onReset: (Int) -> Void
    let onEnd: () -> Void
    var onStep: (Int, Float) -> Void = { _, _ in }
    @State private var draggingBand: Int?
    @State private var dragOriginY: CGFloat = 0
    @GestureState private var dragIsActive = false

    private static let axisHeight: CGFloat = 22

    private func point(_ index: Int, size: CGSize) -> CGPoint {
        let gain = EQGainLimits.clean(gains.indices.contains(index) ? gains[index] : 0, at: index)
        return CGPoint(x: EQGainLimits.graphX(at: index, width: Double(size.width)),
                       y: EQGainLimits.graphY(gain: gain, height: Double(size.height)))
    }
    /// A lane is selected by its horizontal position, even if its node is elsewhere.
    /// This avoids selecting a neighbouring band when a finger covers small nodes.
    private func hitBand(_ location: CGPoint, size: CGSize) -> Int? {
        guard location.x.isFinite, location.y.isFinite, size.width > 28, size.height > 28,
              location.x >= 0, location.x <= size.width,
              location.y >= 0, location.y <= size.height + Self.axisHeight + 6 else { return nil }
        let spacing = (Double(size.width) - 28) / Double(max(1, EQGainLimits.frequencies.count - 1))
        let lane = Int(((Double(location.x) - 14) / spacing).rounded())
        return min(EQGainLimits.frequencies.count - 1, max(0, lane))
    }
    private func resetPoint(at location: CGPoint, size: CGSize) {
        guard let index = hitBand(location, size: size) else { return }
        selectedBand = index
        onReset(index)
        onEnd()
        Haptics.tap(.light)
    }
    private func finishDrag() {
        guard draggingBand != nil else { return }
        draggingBand = nil
        onEnd()
    }
    private func gainText(_ index: Int) -> String {
        String(format: "%+.1f", gains.indices.contains(index) ? gains[index] : 0)
    }

    var body: some View {
        GeometryReader { whole in
            let plotSize = CGSize(width: whole.size.width,
                                  height: max(0, whole.size.height - Self.axisHeight - 6))
            VStack(spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                let topY = CGFloat(EQGainLimits.graphY(gain: EQGainLimits.maximum, height: Double(size.height)))
                let bottomY = CGFloat(EQGainLimits.graphY(gain: -EQGainLimits.maximum, height: Double(size.height)))
                ZStack {
                    // dB guides: ±10, ±5 faint, 0 stronger
                    Path { path in
                        for gain: Float in [10, 5, -5, -10] {
                            let y = CGFloat(EQGainLimits.graphY(gain: gain, height: Double(size.height)))
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    .stroke(SN.ink.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                    Path { path in
                        let zeroY = CGFloat(EQGainLimits.graphY(gain: 0, height: Double(size.height)))
                        path.move(to: CGPoint(x: 0, y: zeroY))
                        path.addLine(to: CGPoint(x: size.width, y: zeroY))
                    }
                    .stroke(SN.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    // Lanes
                    ForEach(EQGainLimits.frequencies.indices, id: \.self) { index in
                        let x = CGFloat(EQGainLimits.graphX(at: index, width: Double(size.width)))
                        let selected = index == selectedBand
                        Capsule(style: .continuous)
                            .fill(selected ? SN.amber.opacity(0.14) : SN.ink.opacity(0.07))
                            .frame(width: selected ? 2 : 1, height: max(0, bottomY - topY))
                            .position(x: x, y: (topY + bottomY) / 2)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: selectedBand)
                    }

                    // Glow between the node curve and 0 дБ.
                    EQControlCurveZeroFillShape(vector: EQCurveVector(gains))
                        .fill(SN.amber.opacity(isEnabled ? 0.10 : 0.04))
                        .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                    // Real summed response, mapped into the node coordinate space.
                    EQAlignedResponseShape(vector: EQCurveVector(gains))
                        .stroke(SN.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 4]))
                        .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                    EQControlCurveShape(vector: EQCurveVector(gains))
                        .stroke(SN.amber, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .shadow(color: SN.amber.opacity(isEnabled ? 0.22 : 0), radius: 4)
                        .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)

                    // Small visual handles; each full lane remains draggable
                    ForEach(EQGainLimits.frequencies.indices, id: \.self) { index in
                        let selected = index == selectedBand
                        let dragging = draggingBand == index
                        ZStack {
                            Circle()
                                .fill(selected ? SN.amber : SN.card)
                                .overlay(Circle().strokeBorder(SN.amber, lineWidth: 1.5))
                                .frame(width: selected ? 14 : 11, height: selected ? 14 : 11)
                            if dragging {
                                Text(gainText(index))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(SN.onAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(SN.amber))
                                    .offset(y: -24)
                                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                        }
                        .scaleEffect(dragging && !reduceMotion ? 1.08 : 1)
                        .position(point(index, size: size))
                        .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: selectedBand)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.14), value: draggingBand)
                        .accessibilityElement()
                        .accessibilityLabel("\(EQFrequencyRegion.bandTitles[index]), \(EQGainLimits.frequencyLabels[index])")
                        .accessibilityValue(String(format: "%+.1f дБ", gains.indices.contains(index) ? gains[index] : 0))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityHint("Смахни вверх или вниз, чтобы изменить на 0,5 дБ")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: onStep(index, 0.5)
                            case .decrement: onStep(index, -0.5)
                            @unknown default: break
                            }
                        }
                    }
                }

            }

            // Axis labels positioned on the exact lane x — not equal-width frames.
            GeometryReader { geometry in
                ForEach(EQGainLimits.frequencies.indices, id: \.self) { index in
                    Text(EQGainLimits.frequencyLabels[index])
                        .font(.caption2.monospacedDigit().weight(selectedBand == index ? .bold : .regular))
                        .foregroundStyle(selectedBand == index ? SN.amber : SN.inkMuted)
                        .fixedSize()
                        .position(x: CGFloat(EQGainLimits.graphX(at: index, width: Double(geometry.size.width))),
                                  y: geometry.size.height / 2)
                }
            }
            .frame(height: Self.axisHeight)
            .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            // Give the plot priority over the enclosing vertical ScrollView. Dragging
            // starts immediately in any lane or on its frequency label; taps never
            // wait for a double-tap recognizer to fail before a drag can begin.
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .updating($dragIsActive) { _, active, _ in active = true }
                .onChanged { value in
                    if draggingBand == nil {
                        guard let closest = hitBand(value.startLocation, size: plotSize) else { return }
                        draggingBand = closest
                        dragOriginY = point(closest, size: plotSize).y
                        selectedBand = closest
                    }
                    guard let index = draggingBand else { return }
                    let rawGain = EQGainLimits.graphGain(y: Double(dragOriginY + value.translation.height), height: Double(plotSize.height), at: index)
                    onChange(index, rawGain)
                }
                .onEnded { _ in finishDrag() })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                resetPoint(at: value.location, size: plotSize)
            })
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { value in
                if let index = hitBand(value.location, size: plotSize), index != selectedBand {
                    selectedBand = index
                    Haptics.tap(.soft)
                }
            })
            .onChange(of: dragIsActive) { _, active in
                if !active { finishDrag() }
            }
            .onDisappear { finishDrag() }
        }
    }
}

/// Tiny preset thumbnail: evenly spaced bands, auto-scaled so gentle presets
/// still read as a shape. Display only — never feeds the audio path.
private struct EQMiniCurve: Shape {
    let gains: [Float]
    func path(in rect: CGRect) -> Path {
        let values = EQGainLimits.normalized(gains)
        var path = Path()
        guard values.count > 1 else { return path }
        let peak = max(6, values.map { abs($0) }.max() ?? 0)
        let points = values.indices.map { index in
            CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: rect.midY - CGFloat(values[index] / peak) * rect.height / 2)
        }
        path.move(to: points[0])
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index], midX = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: midX, y: a.y), control2: CGPoint(x: midX, y: b.y))
        }
        return path
    }
}

private struct EQProfilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    func eqReveal(appeared: Bool, reduceMotion: Bool, delay: Double) -> some View {
        self
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? nil : SN.spring.delay(delay), value: appeared)
    }
}
