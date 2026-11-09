import Foundation
import Observation

/// In-memory diagnostics independent of the optional session log.
struct HTDemucsDiagnosticState {
    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let message: String
    }

    private(set) var pairID: String?
    private var lastPlanType: String?
    private(set) var pairStatus = "Пока нет данных о подготовке пары"
    private(set) var pairUpdatedAt: Date?
    private(set) var lastTransition = "Пока нет данных о выполненном переходе"
    private(set) var lastTransitionAt: Date?
    private(set) var entries: [Entry] = []

    mutating func record(_ message: String, now: Date = Date()) {
        if message.hasPrefix("demucs.pair ") {
            pairID = token("id", in: message)
            lastPlanType = nil
            pairStatus = "Пара выбрана, ожидается анализ"
            pairUpdatedAt = now
            add("Начат анализ пары \(pairID ?? "—")", at: now)
            return
        }
        // Ignore stale results from previous track pairs.
        if message.hasPrefix("demucs."), let id = token("id", in: message), id != pairID { return }

        var status: String?
        if message.hasPrefix("demucs.download.start") { status = "Загрузка модели" }
        else if message.hasPrefix("demucs.download.ready") { status = "Модель загружена; ожидается подготовка стемов" }
        else if message.hasPrefix("demucs.download.failed") { status = "Загрузка модели не удалась: \(humanReason(reason(message)))" }
        else if message.hasPrefix("demucs.plan ") {
            let type = token("type", in: message) ?? "unknown"
            lastPlanType = type
            let bpmA = number("bpmA", in: message, range: 30...400)
            let bpmB = number("bpmB", in: message, range: 30...400)
            let tempo = bpmA.flatMap { a in bpmB.map { b in String(format: " · BPM %.1f → %.1f", a, b) } } ?? ""
            let confA = number("bpmConfA", in: message, range: 0...1)
            let confB = number("bpmConfB", in: message, range: 0...1)
            let confidence = confA.flatMap { a in confB.map { b in String(format: " · уверенность BPM %.2f / %.2f", a, b) } } ?? ""
            let downA = number("downConfA", in: message, range: 0...1)
            let downB = number("downConfB", in: message, range: 0...1)
            let downbeats = downA.flatMap { a in downB.map { b in String(format: " · сетка %.2f / %.2f", a, b) } } ?? ""
            if type == "crossfade" {
                let cause = planCause(token("cause", in: message) ?? "other")
                status = "Для пары выбран кроссфейд (\(cause)); HTDemucs не запускается\(tempo)\(confidence)\(downbeats)"
            } else if type == "none" { status = "План не разрешил переход; HTDemucs не запускается\(tempo)" }
            else { status = "План \(type): ожидается подготовка стемов\(tempo)\(confidence)\(downbeats)" }
        }
        else if message.hasPrefix("demucs.prewarm.start") { status = "Подготовка HTDemucs запущена" }
        else if message.hasPrefix("demucs.prewarm.model-load-start") { status = "Открытие модели Core ML" }
        else if message.hasPrefix("demucs.prewarm.outgoing-window") { status = "Разделение текущего трека" }
        else if message.hasPrefix("demucs.prewarm.incoming-window") { status = "Разделение следующего трека" }
        else if message.hasPrefix("demucs.separate.ready") {
            status = token("role", in: message) == "incoming" ? "Следующий трек разделён" : "Текущий трек разделён"
        }
        else if message.hasPrefix("demucs.prewarm.ready") { status = "Стемы пары подготовлены; применение в переходе ещё не подтверждено" }
        else if message.hasPrefix("demucs.prewarm.cancelled") { status = "Подготовка отменена (например, при смене трека)" }
        else if message.hasPrefix("demucs.prewarm.failed") { status = "Подготовка не удалась: \(humanReason(reason(message)))" }
        else if message.hasPrefix("demucs.prewarm.skipped") {
            let code = reason(message)
            // The plan event already records this same decision with more detail.
            if code == "plan-crossfade", lastPlanType == "crossfade" { return }
            if code == "plan-none", lastPlanType == "none" { return }
            status = skippedReason(code)
        }
        if let status {
            pairStatus = status
            pairUpdatedAt = now
            add(status, at: now)
            return
        }

        var outcome: String?
        if message.hasPrefix("bake.ready ") {
            let backend = token("sep", in: message) ?? "unknown"
            outcome = backend == "htdemucs" ? "HTDemucs применён в переходе" : "Переход подготовлен без HTDemucs: \(backend)"
        } else if message.hasPrefix("bake.demucs fallback=") {
            outcome = "Переход использует запасной вариант: \(humanReason(reason(message, key: "fallback")))"
        } else if message.hasPrefix("transition.safe-crossfade ") {
            outcome = "Запланирован безопасный кроссфейд; выполнение ещё не подтверждено"
        } else if message.hasPrefix("demucs.bake.cache.busy-miss") {
            outcome = "Подготовка занята, нужные стемы ещё не готовы"
        }
        if let outcome {
            lastTransition = outcome
            lastTransitionAt = now
            add(outcome, at: now)
        }
    }

    private mutating func add(_ message: String, at: Date) {
        entries.append(Entry(time: at, message: message))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }
    private func token(_ key: String, in text: String) -> String? {
        guard let part = text.split(separator: " ").first(where: { $0.hasPrefix(key + "=") }) else { return nil }
        let raw = part.dropFirst(key.count + 1)
        let safe = raw.prefix(64).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return safe.isEmpty ? nil : String(safe)
    }
    private func number(_ key: String, in text: String, range: ClosedRange<Double>) -> Double? {
        guard let part = text.split(separator: " ").first(where: { $0.hasPrefix(key + "=") }),
              let value = Double(part.dropFirst(key.count + 1)), value.isFinite, range.contains(value) else { return nil }
        return value
    }
    private func planCause(_ code: String) -> String {
        switch code {
        case "tempo": return "темпы"
        case "key": return "тональности"
        case "grid": return "сетка"
        case "phase": return "фаза долей"
        case "short": return "короткий трек"
        case "unmixable": return "трек не предназначен для сведения"
        default: return "другая причина"
        }
    }
    private func reason(_ message: String, key: String = "reason") -> String {
        token(key, in: message) ?? "неизвестная причина"
    }
    private func humanReason(_ code: String) -> String {
        if code.hasPrefix("network-") { return "ошибка сети (\(code))" }
        switch code {
        case "model-not-installed": return "модель не установлена (\(code))"
        case "model-load-refused": return "модель временно не открывается (\(code))"
        case "window-not-ready": return "окно стемов не готово (\(code))"
        case "window-outside-cache": return "нужный участок вне подготовленного кэша (\(code))"
        case "insufficient-storage": return "недостаточно свободного места (\(code))"
        case "incomplete-download", "model-file-size-mismatch": return "файлы модели неполные (\(code))"
        case "source-file-changed": return "аудиофайл изменился (\(code))"
        default: return code
        }
    }
    private func skippedReason(_ code: String) -> String {
        switch code {
        case "no-next-track": return "Нет следующего трека для анализа"
        case "plan-crossfade": return "Для пары выбран кроссфейд; HTDemucs не запускается"
        case "plan-none": return "План не разрешил переход; HTDemucs не запускается"
        case "model-load-refused": return "Модель временно не открывается; повторная попытка позже"
        case "analysis-failed": return "Не удалось проанализировать пару"
        default: return "Подготовка пропущена: \(code)"
        }
    }
}

@Observable @MainActor
final class HTDemucsDiagnostics {
    static let shared = HTDemucsDiagnostics()
    private(set) var state = HTDemucsDiagnosticState()
    private init() {}
    func record(_ message: String) { state.record(message) }
}
