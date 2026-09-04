import AudioEngineCore
import SwiftUI

struct AutoMixV2DiagnosticsView: View {
    @State private var selection = AutoMixEngineSelectionStore.shared
    @State private var runtime = AutoMixV2Runtime.shared

    var body: some View {
        List {
            Section("Состояние") {
                LabeledContent("Движок", value: selection.isV2Enabled ? "AutoMix V2" : "Legacy")
                LabeledContent("Воспроизведение", value: runtime.isPlaying ? "Играет" : "Остановлено")
                LabeledContent("Загрузка", value: runtime.isLoading ? "Да" : "Нет")
                if let error = runtime.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Бюджеты") {
                LabeledContent("PCM preload", value: ByteCountFormatter.string(fromByteCount: Int64(PCMPreloadPolicy().estimatedTotalQueuedBytes), countStyle: .memory))
                LabeledContent("Лимит PCM", value: "25 МБ")
                LabeledContent("Лимит движка", value: "50 МБ")
            }

            Section("Отчёт") {
                Button("Обновить отчёт") {
                    Task { await runtime.refreshDiagnostics() }
                }
                Text(runtime.diagnosticReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("AutoMix V2")
        .task { await runtime.refreshDiagnostics() }
    }
}
