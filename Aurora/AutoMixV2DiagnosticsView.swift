import AudioEngineCore
import MixModels
import MixPlanner
import SwiftUI

struct AutoMixV2DiagnosticsView: View {
    @State private var selection = AutoMixEngineSelectionStore.shared
    @State private var runtime = AutoMixV2Runtime.shared
    @State private var analysis = AutoMixV2AnalysisRuntime.shared

    private var visibleError: String? {
        let value = runtime.lastError ?? analysis.lastError
        guard let value else { return nil }
        let lowered = value.lowercased()
        if lowered.contains("code=-999") || lowered.contains("cancelled") || lowered.contains("отменено") { return nil }
        return value
    }

    var body: some View {
        List {
            Section("Состояние") {
                LabeledContent("Движок", value: selection.isV2Enabled ? "AutoMix V2" : "Обычный")
                LabeledContent("Воспроизведение", value: runtime.isPlaying ? "Играет" : "Остановлено")
                LabeledContent("Загрузка", value: runtime.isLoading ? "Да" : "Нет")
                LabeledContent("Анализ", value: analysis.pipelineStatus)
                if let error = visibleError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            profileSection("Текущий трек", profile: analysis.currentProfile)
            profileSection("Следующий трек", profile: analysis.nextProfile)
            if let plan = analysis.transitionPlan {
                Section("План, синхронизация и FX") {
                    LabeledContent("Тип", value: plan.type.rawValue)
                    LabeledContent("Причина", value: plan.reason)
                    LabeledContent("Target BPM", value: String(format: "%.2f", plan.tempoTargetBPM))
                    LabeledContent("Rate A", value: String(format: "%.5f", plan.rateA))
                    LabeledContent("Rate B", value: String(format: "%.5f", plan.rateB))
                    LabeledContent("Начало A", value: String(format: "%.3f с", plan.aOutStartSec))
                    LabeledContent("Старт B", value: String(format: "%.3f с", plan.bInStartSec))
                    LabeledContent("Тактов", value: String(format: "%.0f", plan.bars))
                    LabeledContent("FX событий", value: String(plan.fx.count))
                    ForEach(Array(plan.fx.enumerated()), id: \.offset) { _, event in
                        LabeledContent(event.kind.rawValue, value: event.target.rawValue.uppercased())
                    }
                }
            }
            Section("Действия") {
                Button("Пересчитать профиль текущего трека") { analysis.recalculateCurrent() }
                Button("Обновить runtime-отчёт") { Task { await runtime.refreshDiagnostics() } }
                Text(runtime.diagnosticReport).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }
        .navigationTitle("AutoMix V2")
        .task { analysis.install(); await runtime.refreshDiagnostics() }
    }

    @ViewBuilder
    private func profileSection(_ title: String, profile: TrackProfile?) -> some View {
        Section(title) {
            if let profile {
                LabeledContent("BPM", value: String(format: "%.1f", profile.bpm))
                LabeledContent("BPM confidence", value: String(format: "%.2f", profile.confidence.bpm))
                LabeledContent("Downbeat confidence", value: String(format: "%.2f", profile.confidence.downbeats))
                LabeledContent("Camelot", value: profile.camelotKey ?? "Не определён")
                LabeledContent("LUFS", value: String(format: "%.1f", profile.integratedLUFS))
                LabeledContent("Mixable", value: profile.mixable ? "Да" : "Нет")
                LabeledContent("Mix in", value: String(format: "%.1f с", profile.mixInSec))
                LabeledContent("Mix out", value: String(format: "%.1f с", profile.mixOutSec))
            } else { Text("Профиль ещё не готов").foregroundStyle(.secondary) }
        }
    }
}
