// Path: Aurora/DJAutoMixEngine/DJTransitionPlanner.swift
import Foundation

public protocol DJTransitionPlanner: Sendable {
    nonisolated func plan(outgoing: DJTrackAnalysis, incoming: DJTrackAnalysis) -> DJTransitionType
}

public struct DefaultDJTransitionPlanner: DJTransitionPlanner, Sendable {
    public var maxTempoDiffPct: Double = 0.06       // ≤ 6% разница темпа
    public var minConfidence: Double = 0.65         // Минимальная достоверность анализа
    public var minSilenceForCrossfade: TimeInterval = 0.30 // ≥ 300 мс тишины для simpleCrossfade
    public var defaultCrossfadeDuration: TimeInterval = 4.0
    public var targetMixBars: Double = 8.0          // Длина DJ-сведения (8 тактов)

    public init(
        maxTempoDiffPct: Double = 0.06,
        minConfidence: Double = 0.65,
        minSilenceForCrossfade: TimeInterval = 0.30,
        defaultCrossfadeDuration: TimeInterval = 4.0,
        targetMixBars: Double = 8.0
    ) {
        self.maxTempoDiffPct = maxTempoDiffPct
        self.minConfidence = minConfidence
        self.minSilenceForCrossfade = minSilenceForCrossfade
        self.defaultCrossfadeDuration = defaultCrossfadeDuration
        self.targetMixBars = targetMixBars
    }

    nonisolated public func plan(outgoing: DJTrackAnalysis, incoming: DJTrackAnalysis) -> DJTransitionType {
        // 1. Проверка уверенности анализа (п. 4 ТЗ: Низкий confidence -> hardCut)
        guard outgoing.confidence >= minConfidence, incoming.confidence >= minConfidence else {
            return .hardCut
        }

        // 2. Проверка темповой совместимости (с учетом double/half-time: 87 ↔ 174 BPM)
        let tempoMatch = matchTempo(outgoingBPM: outgoing.bpm, incomingBPM: incoming.bpm)

        // 3. Проверка тональной совместимости по Camelot Wheel
        let harmonicMatch = outgoing.key.isHarmonicallyCompatible(with: incoming.key)

        // 4. Музыкально оправданное DJ-сведение (BPM ≤ 6% И Camelot совместимы И confidence высок)
        if tempoMatch.isCompatible, harmonicMatch {
            let plan = buildDJMixPlan(
                outgoing: outgoing,
                incoming: incoming,
                tempoRatio: tempoMatch.tempoRatio,
                targetBPM: outgoing.bpm
            )
            return .djStyleMix(plan)
        }

        // 5. Фоллбэк 1: Тишина в начале/конце ≥ 300 мс, но темп/тональность не совместимы -> simpleCrossfade
        let hasSilence = outgoing.trailingSilence >= minSilenceForCrossfade
            || incoming.leadInSilence >= minSilenceForCrossfade

        if hasSilence {
            return .simpleCrossfade(duration: defaultCrossfadeDuration)
        }

        // 6. Фоллбэк 2: Несовместимая пара без тишины -> hardCut
        return .hardCut
    }

    /// Сравнение темпа с учетом half-time и double-time:
    /// Возвращает ближайший эквивалентный темп, процент расхождения и коэффициент растяжения.
    nonisolated public func matchTempo(outgoingBPM: Double, incomingBPM: Double) -> (isCompatible: Bool, tempoRatio: Double, diffPct: Double) {
        guard outgoingBPM > 30, incomingBPM > 30 else {
            return (false, 1.0, 1.0)
        }

        let candidates = [incomingBPM, incomingBPM * 2.0, incomingBPM / 2.0]
        let closest = candidates.min(by: { abs($0 - outgoingBPM) < abs($1 - outgoingBPM) }) ?? incomingBPM

        let diffPct = abs(closest - outgoingBPM) / outgoingBPM
        let isCompatible = diffPct <= maxTempoDiffPct
        let tempoRatio = outgoingBPM / closest

        return (isCompatible, tempoRatio, diffPct)
    }

    nonisolated private func buildDJMixPlan(
        outgoing: DJTrackAnalysis,
        incoming: DJTrackAnalysis,
        tempoRatio: Double,
        targetBPM: Double
    ) -> DJMixPlan {
        let barDuration = 240.0 / max(40.0, targetBPM) // 4 четверти на такт
        let rawDuration = barDuration * targetMixBars
        let mixDuration = min(20.0, max(10.0, rawDuration))

        // Точка входа входящего трека: сразу после тишины, с привязкой к первой доле
        var entryPoint = incoming.leadInSilence
        if let firstBeat = incoming.beatGrid.first(where: { $0 >= incoming.leadInSilence }) {
            entryPoint = firstBeat
        }

        // Точка выхода уходящего трека: ищем outro в структуре, либо отступаем mixDuration от конца
        let totalOutgoingDuration = outgoing.beatGrid.last ?? (outgoing.structure.last?.range.upperBound ?? 180.0)
        var exitPoint = max(0.0, totalOutgoingDuration - mixDuration - outgoing.trailingSilence)

        if let outroSegment = outgoing.structure.last(where: { !$0.isVocal && $0.energy < 0.65 }) {
            if outroSegment.range.lowerBound >= (totalOutgoingDuration - mixDuration - 8.0) {
                exitPoint = outroSegment.range.lowerBound
            }
        }

        // Привязываем exitPoint к ближайшей доле уходящего трека
        if let nearestBeat = outgoing.beatGrid.min(by: { abs($0 - exitPoint) < abs($1 - exitPoint) }) {
            exitPoint = nearestBeat
        }

        // Автоматизация EQ для передачи баса (Bass Swap) на 50% перехода
        let eqKeyframes: [EQKeyframe] = [
            // Уходящий трек держит бас до середины перехода, затем срез
            EQKeyframe(time: 0.0, band: .lowShelf, gainDB: 0.0, duration: 0.0),
            EQKeyframe(time: mixDuration * 0.48, band: .lowShelf, gainDB: 0.0, duration: 0.0),
            EQKeyframe(time: mixDuration * 0.50, band: .lowShelf, gainDB: -24.0, duration: mixDuration * 0.04),

            // Входящий трек приглушен по басу первые 50%, затем взрыв баса на downbeat
            EQKeyframe(time: 0.0, band: .lowShelf, gainDB: -24.0, duration: 0.0),
            EQKeyframe(time: mixDuration * 0.50, band: .lowShelf, gainDB: -24.0, duration: 0.0),
            EQKeyframe(time: mixDuration * 0.52, band: .lowShelf, gainDB: 0.0, duration: mixDuration * 0.04)
        ]

        return DJMixPlan(
            duration: mixDuration,
            outgoingExitPoint: exitPoint,
            incomingEntryPoint: entryPoint,
            tempoRatio: tempoRatio,
            volumeCurve: .djMashup,
            eqAutomation: eqKeyframes
        )
    }
}
