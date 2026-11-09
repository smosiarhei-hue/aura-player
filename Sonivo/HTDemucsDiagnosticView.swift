import AudioEngineCore
import SwiftUI
import UIKit

/// Passive status check; no extra separation or download.
struct HTDemucsDiagnosticView: View {
    @State private var diagnostics = HTDemucsDiagnostics.shared
    @State private var analysis = AutoMixV2AnalysisRuntime.shared
    @State private var player = PlayerCore.shared
    @State private var modelStatus = "Проверка…"
    @State private var copied = false

    private var modeSupportsStems: Bool { player.transitionMode == .automix || player.transitionMode == .duet }
    private var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Норма"
        case .fair: return "Умеренный нагрев"
        case .serious: return "Сильный нагрев — вычисления могут замедлиться"
        case .critical: return "Критический нагрев — вычисления могут замедлиться"
        @unknown default: return "Неизвестно"
        }
    }

    var body: some View {
        Form {
            Section("Сейчас") {
                LabeledContent("Режим", value: player.transitionMode.rawValue)
                LabeledContent("Воспроизведение", value: player.isPlaying ? "Идёт" : "Пауза или остановлено")
                LabeledContent("Модель", value: modelStatus)
                LabeledContent("Анализ пары", value: analysis.pipelineStatus)
                if let status = analysis.stemStatus { LabeledContent("Подготовка", value: status) }
                if !modeSupportsStems {
                    Text("Для разделения выберите AutoMix Mashup или Duet. В остальных режимах оно обычно не запускается.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Последняя подготовка") {
                Text(diagnostics.state.pairStatus)
                if let time = diagnostics.state.pairUpdatedAt {
                    Text("Обновлено: \(time.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Последнее событие перехода") {
                Text(diagnostics.state.lastTransition)
                if let time = diagnostics.state.lastTransitionAt {
                    Text("Обновлено: \(time.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Возможные ограничения") {
                LabeledContent("Нагрев", value: thermal)
                LabeledContent("Энергосбережение", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "Включено" : "Выключено")
                Text("HTDemucs использует CPU. Переключатель Neural Engine в настройках относится к анализу текста и не включает и не выключает HTDemucs.")
                Text("Нагрев и энергосбережение могут замедлять обработку, но сами по себе не доказывают конфликт.")
            }
            .font(.subheadline)
            Section("Последние события") {
                if diagnostics.state.entries.isEmpty {
                    Text("Событий пока нет. Включите AutoMix и дайте текущему и следующему треку подготовиться.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(diagnostics.state.entries.suffix(20).reversed())) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.message)
                            Text(entry.time.formatted(date: .omitted, time: .standard))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button { Task { await refreshModelStatus() } } label: {
                    Label("Обновить проверку", systemImage: "arrow.clockwise")
                }
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label("Скопировать диагностику HTDemucs", systemImage: "doc.on.clipboard")
                }
                if copied { Text("Скопировано — можно вставить отчёт в чат.").font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Проверка не запускает тестовое разделение и не останавливает музыку. Стемы считаются применёнными только после соответствующего события перехода. История хранится в памяти до закрытия приложения, не содержит названий треков и не отправляется автоматически.")
            }
        }
        .navigationTitle("Диагностика HTDemucs")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await refreshModelStatus()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    @MainActor private func refreshModelStatus() async {
        let reason = await HTDemucsMashupBake.unavailableReason()
        switch reason {
        case "model-not-installed": modelStatus = "Не установлена или файлы неполные"
        case "model-load-refused": modelStatus = "Не удалось открыть; повторная попытка позже"
        default: modelStatus = "Файлы модели найдены; работоспособность не проверена отдельно"
        }
    }

    private var report: String {
        let state = diagnostics.state
        let lines = state.entries.suffix(30).map {
            "[\($0.time.formatted(date: .omitted, time: .standard))] \($0.message)"
        }.joined(separator: "\n")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return """
        Sonivo HTDemucs Diagnostic
        App: \(version) (\(build))
        Device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Mode: \(player.transitionMode.rawValue)
        Playing: \(player.isPlaying)
        Model: \(modelStatus)
        Analysis: \(analysis.pipelineStatus)
        Last preparation: \(state.pairStatus)
        Last transition event: \(state.lastTransition)
        Thermal: \(thermal)
        Low power: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
        Events (this app session, oldest first):
        \(lines.isEmpty ? "Нет событий" : lines)
        """
    }
}
