// Path: Sonivo/PlayerEQSheetView.swift
import Observation
import SwiftUI

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
    private let frequencyLabels = EQGainLimits.frequencies.map { "\(Int($0)) Гц" }
    /// Flat → Bass → Deep bass → Bass+Treble → Classical → Club → Dance
    private var primaryPresets: [EQPreset] {
        [EQPresets.flat, EQPresets.bassBoost, EQPresets.subBassPower, EQPresets.bassTrebleBoost,
         EQPresets.classical, EQPresets.club, EQPresets.dance]
    }
    /// Generic earphone taste — not a device calibration.
    private var secondaryPresets: [EQPreset] { [EQPresets.airPodsPro2Bass] }
    private var activePreset: EQPreset? { EQPresets.all.first { matches($0.gains) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    masterHeader
                    heroCurve
                    bandEditor
                    profilesSection
                    savedPresetsSection
                    outputCard
                    listeningNote
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 36)
                .opacity(appeared || reduceEQMotion ? 1 : 0)
                .offset(y: appeared || reduceEQMotion ? 0 : 14)
            }
            .background {
                ZStack {
                    SN.bg
                    RadialGradient(
                        colors: [SN.amber.opacity(player.eqEnabled ? 0.14 : 0.05), .clear],
                        center: .top, startRadius: 20, endRadius: 420
                    )
                    .ignoresSafeArea()
                    .animation(reduceEQMotion ? nil : SN.slowSpring, value: player.eqEnabled)
                }
            }
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

    private var masterHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $player.eqEnabled.animation(reduceEQMotion ? nil : SN.fastSpring)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Эквалайзер")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(SN.ink)
                    Text(player.eqEnabled
                         ? (activePreset?.name ?? userPresets.presets.first(where: { matches($0.gains) })?.name ?? "Своя кривая")
                         : "Выключен · исходный звук")
                        .font(.subheadline)
                        .foregroundStyle(SN.inkMuted)
                }
            }
            .tint(SN.amber)
            .accessibilityLabel("Эквалайзер")
            Label(eqStatusText, systemImage: player.isEQEffectivelyActive ? "waveform" : "minus.circle")
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heroCurve: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Кривая").font(.headline)
                Spacer()
                Text("±15 дБ").font(.subheadline.monospacedDigit()).foregroundStyle(SN.inkMuted)
            }
            ZStack {
                RoundedRectangle(cornerRadius: SN.radiusLarge, style: .continuous)
                    .fill(SN.card.opacity(0.72))
                EQFrequencyResponseFillShape(vector: EQCurveVector(player.eqGains))
                    .fill(LinearGradient(colors: [SN.amber.opacity(0.22), SN.amber.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(10)
                    .animation(reduceEQMotion || isAdjustingEQ ? nil : .smooth(duration: 0.28), value: player.eqGains)
                EQFrequencyResponseShape(vector: EQCurveVector(player.eqGains))
                    .stroke(SN.amber.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(10)
                    .animation(reduceEQMotion || isAdjustingEQ ? nil : .smooth(duration: 0.28), value: player.eqGains)
                CompactEQCurve(gains: player.eqGains, selectedBand: $selectedBand, isInteracting: isAdjustingEQ,
                               onChange: { setBandGain($0, $1) }, onReset: { setBandGain($0, 0, feedback: false) }, onEnd: { player.saveEQ() })
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 200 : 260)
            .overlay(
                RoundedRectangle(cornerRadius: SN.radiusLarge, style: .continuous)
                    .strokeBorder(SN.ink.opacity(0.08), lineWidth: 1)
            )
            .opacity(player.eqEnabled ? 1 : 0.45)
            .disabled(!player.eqEnabled)
            .accessibilityHidden(true)
            Text("Суммарная АЧХ · модель PCM 48 кГц · не измерение наушников")
                .font(.caption).foregroundStyle(SN.inkMuted)
            Text("Двойной тап по точке — 0 дБ")
                .font(.caption).foregroundStyle(SN.inkMuted)
        }
    }

    private var bandEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Полоса").font(.headline)
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
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(PlayerCore.bandFrequencies.indices, id: \.self) { index in
                        bandRow(index)
                        if index < PlayerCore.bandFrequencies.count - 1 { Divider() }
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PlayerCore.bandFrequencies.indices, id: \.self) { index in
                            Button {
                                withAnimation(reduceEQMotion ? nil : SN.fastSpring) { selectedBand = index }
                            } label: {
                                VStack(spacing: 4) {
                                    Text(compactFrequency(index))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                    Text(bandNames[index])
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .foregroundStyle(selectedBand == index ? SN.onAccent : SN.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Capsule(style: .continuous).fill(selectedBand == index ? SN.amber : SN.card))
                                .overlay(Capsule(style: .continuous).strokeBorder(SN.ink.opacity(selectedBand == index ? 0 : 0.1), lineWidth: 1))
                            }
                            .buttonStyle(EQProfilePressStyle())
                            .accessibilityLabel("Выбрать \(frequencyLabels[index])")
                            .accessibilityValue(db(player.eqGains.indices.contains(index) ? player.eqGains[index] : 0))
                            .accessibilityAddTraits(selectedBand == index ? .isSelected : [])
                        }
                    }
                }
                bandRow(selectedBand)
                    .padding(.top, 4)
            }
            if !player.eqEnabled {
                Text("Включи EQ, чтобы изменить полосы. Сохранённая настройка не сбрасывается.")
                    .font(.subheadline).foregroundStyle(SN.inkMuted)
            }
        }
        .disabled(!player.eqEnabled)
        .opacity(player.eqEnabled ? 1 : 0.55)
        .foregroundStyle(SN.ink)
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пресеты").font(.headline).foregroundStyle(SN.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(primaryPresets) { preset in presetChip(preset) }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(secondaryPresets) { preset in
                        presetChip(preset).opacity(0.78)
                    }
                }
            }
            Text("Только полосные фильтры — без сжатия микса и без peak duck. Начни с +2…+4 дБ.")
                .font(.subheadline)
                .foregroundStyle(SN.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetChip(_ preset: EQPreset) -> some View {
        let selected = matches(preset.gains)
        return Button { applyPreset(preset) } label: {
            HStack(spacing: 8) {
                Image(systemName: presetIcon(preset)).accessibilityHidden(true)
                Text(preset.name).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? SN.onAccent : SN.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Capsule(style: .continuous).fill(selected ? SN.amber : SN.card))
            .overlay(Capsule(style: .continuous).strokeBorder(SN.ink.opacity(selected ? 0 : 0.12), lineWidth: 1))
        }
        .buttonStyle(EQProfilePressStyle())
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                        withAnimation(reduceEQMotion ? nil : SN.fastSpring) {
                            player.eqGains = preset.gains
                            player.eqEnabled = true
                        }
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
    }

    private func bandRow(_ index: Int) -> some View {
        let gain = player.eqGains.indices.contains(index) ? player.eqGains[index] : 0
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    bandTitle(index)
                    Spacer(minLength: 16)
                    Text(db(gain)).font(.title3.weight(.semibold).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 8) {
                    bandTitle(index)
                    Text(db(gain)).font(.title3.weight(.semibold).monospacedDigit())
                }
            }
            Slider(value: Binding(
                get: { Double(player.eqGains.indices.contains(index) ? player.eqGains[index] : 0) },
                set: { value in setBandGain(index, Float(value)) }
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
        .padding(.top, 8)
    }

    private func bandTitle(_ index: Int) -> some View {
        Text("\(bandNames[index]) \(frequencyLabels[index])")
            .font(.headline)
            .foregroundStyle(SN.ink)
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
            Label("Только полосы частот", systemImage: "slider.vertical.3")
                .font(.subheadline.weight(.semibold))
            Text("EQ поднимает и режет выбранные частоты. Басовый удар не сжимает и не приглушает весь трек — filters-only, нет peak guard и нет PeakLimiter на миксе.")
            Text("Полка 60 Гц и удар 120 Гц; 250 Гц режет гул. 16 кГц — верхняя полоса.")
            Text("Плоский и выключенный EQ — исходный сигнал. Сильный подъём может клиппировать запись; начни с умеренной громкости.")
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
    private func db(_ gain: Float) -> String { String(format: "%+.1f дБ", gain) }
    private func presetIcon(_ preset: EQPreset) -> String {
        if preset == EQPresets.airPodsPro2Bass { return "earbuds" }
        if preset == EQPresets.flat { return "slider.horizontal.3" }
        if preset == EQPresets.bassBoost || preset == EQPresets.subBassPower { return "speaker.wave.3" }
        return "waveform"
    }
}

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
                EQControlCurveFillShape(vector: EQCurveVector(gains))
                    .fill(LinearGradient(colors: [SN.amber.opacity(0.16), SN.amber.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                EQControlCurveShape(vector: EQCurveVector(gains))
                    .stroke(LinearGradient(colors: [SN.amber, SN.amber.opacity(0.7), SN.amber],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                ForEach(EQGainLimits.frequencies.indices, id: \.self) { index in
                    Circle().fill(SN.card)
                        .overlay(Circle().stroke(SN.amber, lineWidth: index == selectedBand ? 3 : 2))
                        .frame(width: index == selectedBand ? 20 : 12, height: index == selectedBand ? 20 : 12)
                        .scaleEffect(index == selectedBand && !reduceMotion ? 1.05 : 1)
                        .position(point(index, size: size))
                        .animation(reduceMotion || isInteracting || draggingBand != nil ? nil : .smooth(duration: 0.24), value: gains)
                        .animation(reduceMotion ? nil : SN.fastSpring, value: selectedBand)
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
                if let index = hitBand(value.location, size: size) {
                    withAnimation(reduceMotion ? nil : SN.fastSpring) { selectedBand = index }
                }
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

