import Foundation

public protocol NeuroTransitionScoring: Sendable {
    func score(source: NeuroTrackFeatures, target: NeuroTrackFeatures, kind: NeuroTransitionKind) -> Double
}

public struct NeuroHeuristicScorer: NeuroTransitionScoring {
    public init() {}

    public func score(
        source: NeuroTrackFeatures,
        target: NeuroTrackFeatures,
        kind: NeuroTransitionKind
    ) -> Double {
        let energyContinuity = 1 - min(1, abs(source.energy - target.energy))
        let vocalSafety = 1 - min(1, source.vocalActivity * target.vocalActivity)
        let keySafety = source.key != nil && source.key == target.key
            ? min(source.keyConfidence, target.keyConfidence)
            : 0.5

        switch kind {
        case .beatmatch:
            guard let sourceBPM = source.bpm, let targetBPM = target.bpm,
                  sourceBPM > 0, targetBPM > 0 else { return 0 }
            let ratio = min(sourceBPM, targetBPM) / max(sourceBPM, targetBPM)
            return min(1, max(0, ratio * 0.55 + energyContinuity * 0.2
                              + vocalSafety * 0.15 + keySafety * 0.1))
        case .crossfade:
            return energyContinuity * 0.55 + vocalSafety * 0.25 + keySafety * 0.2
        case .filterOut:
            return energyContinuity * 0.35 + vocalSafety * 0.5 + keySafety * 0.15
        case .hardCut:
            return (target.endsInSilence || source.endsInSilence) ? 0.65 : 0.25
        case .none:
            return 0
        }
    }
}

public struct NeuroMixEngine: Sendable {
    private let scorer: any NeuroTransitionScoring

    public init(scorer: any NeuroTransitionScoring = NeuroHeuristicScorer()) {
        self.scorer = scorer
    }

    public func makePlan(
        source: NeuroTrackFeatures,
        target: NeuroTrackFeatures,
        settings: NeuroMixSettings = NeuroMixSettings()
    ) -> NeuroTransitionPlan {
        let candidates = makeCandidates(source: source, target: target, settings: settings)
        guard let best = candidates.max(by: { $0.score < $1.score }),
              best.score >= settings.minimumConfidence else {
            return fallback(source: source, target: target, settings: settings)
        }
        return best
    }

    private func makeCandidates(
        source: NeuroTrackFeatures,
        target: NeuroTrackFeatures,
        settings: NeuroMixSettings
    ) -> [NeuroTransitionPlan] {
        var candidates = [
            candidate(.crossfade, source: source, target: target,
                      duration: settings.crossfadeSeconds, sourceRate: 1, targetRate: 1)
        ]

        if let sourceBPM = source.bpm, let targetBPM = target.bpm,
           sourceBPM > 0, targetBPM > 0 {
            let targetRate = sourceBPM / targetBPM
            let correction = abs(targetRate - 1)
            if correction <= settings.maxTempoCorrection,
               source.bpmConfidence >= settings.minimumConfidence,
               target.bpmConfidence >= settings.minimumConfidence {
                candidates.append(candidate(
                    .beatmatch,
                    source: source,
                    target: target,
                    duration: min(16, max(4, settings.crossfadeSeconds * 2)),
                    sourceRate: 1,
                    targetRate: targetRate
                ))
            }
        }

        if source.vocalActivity * target.vocalActivity > 0.45 {
            candidates.append(candidate(
                .filterOut,
                source: source,
                target: target,
                duration: min(10, max(4, settings.crossfadeSeconds)),
                sourceRate: 1,
                targetRate: 1
            ))
        }
        return candidates
    }

    private func candidate(
        _ kind: NeuroTransitionKind,
        source: NeuroTrackFeatures,
        target: NeuroTrackFeatures,
        duration: Double,
        sourceRate: Double,
        targetRate: Double
    ) -> NeuroTransitionPlan {
        NeuroTransitionPlan(
            sourceTrackID: source.trackID,
            targetTrackID: target.trackID,
            kind: kind,
            durationSeconds: duration,
            sourceStartSeconds: max(0, source.durationSeconds - duration),
            targetStartSeconds: target.endsInSilence ? 0 : min(8, target.durationSeconds * 0.08),
            sourceRate: sourceRate,
            targetRate: targetRate,
            sourceGain: 1,
            targetGain: 1,
            score: scorer.score(source: source, target: target, kind: kind),
            reason: reason(for: kind),
            usedFallback: false
        )
    }

    private func fallback(
        source: NeuroTrackFeatures,
        target: NeuroTrackFeatures,
        settings: NeuroMixSettings
    ) -> NeuroTransitionPlan {
        NeuroTransitionPlan(
            sourceTrackID: source.trackID,
            targetTrackID: target.trackID,
            kind: .crossfade,
            durationSeconds: min(settings.crossfadeSeconds, max(0, source.durationSeconds)),
            sourceStartSeconds: max(0, source.durationSeconds - settings.crossfadeSeconds),
            targetStartSeconds: 0,
            sourceRate: 1,
            targetRate: 1,
            sourceGain: 1,
            targetGain: 1,
            score: 0.5,
            reason: "Недостаточная уверенность; безопасный crossfade",
            usedFallback: true
        )
    }

    private func reason(for kind: NeuroTransitionKind) -> String {
        switch kind {
        case .beatmatch: return "Beatmatch по близкому BPM"
        case .crossfade: return "Плавный crossfade"
        case .filterOut: return "Снижение вокального конфликта через filter transition"
        case .hardCut: return "Hard cut"
        case .none: return "Переход отключён"
        }
    }
}
