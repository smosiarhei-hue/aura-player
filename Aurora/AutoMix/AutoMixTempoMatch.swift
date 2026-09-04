// Path: Aurora/AutoMix/AutoMixTempoMatch.swift

import Foundation

nonisolated struct TempoMatch: Sendable {
    let sourceBPM: Double?
    let targetBPM: Double?
    let sourceRate: Double
    let targetRate: Double
    let score: Double
    let canSynchronize: Bool
}

extension TransitionPlanner {
    nonisolated static func tempoMatch(source: TrackAnalysis, target: TrackAnalysis) -> TempoMatch {
        guard let sourceBPM = normalizedBPM(source.bpm),
              let targetBPM = normalizedBPM(target.bpm),
              source.bpmConfidence >= 0.30,
              target.bpmConfidence >= 0.30 else {
            return TempoMatch(sourceBPM: nil, targetBPM: nil, sourceRate: 1, targetRate: 1, score: 0.35, canSynchronize: false)
        }

        let commonBPM = sqrt(sourceBPM * targetBPM)
        let sourceRate = commonBPM / sourceBPM
        let targetRate = commonBPM / targetBPM
        let ratio = max(sourceBPM, targetBPM) / min(sourceBPM, targetBPM)
        let ratesAreSafe = sourceRate >= minStretch && sourceRate <= maxStretch
            && targetRate >= minStretch && targetRate <= maxStretch
        let confidence = min(source.bpmConfidence, target.bpmConfidence)
        let score = rhythmScore(sourceBPM: sourceBPM, targetBPM: targetBPM) * confidence

        return TempoMatch(
            sourceBPM: sourceBPM,
            targetBPM: targetBPM,
            sourceRate: ratesAreSafe ? sourceRate : 1,
            targetRate: ratesAreSafe ? targetRate : 1,
            score: score,
            canSynchronize: ratesAreSafe && ratio <= 1.13
        )
    }
}
