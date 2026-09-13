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
        let keySafety = harmonicCompatibility(source: source, target: target)
        let phraseSafety = phraseCompatibility(source: source, target: target)
        let loudnessSafety = loudnessCompatibility(source: source, target: target)

        switch kind {
        case .beatmatch:
            guard let sourceBPM = source.bpm, let targetBPM = target.bpm,
                  sourceBPM > 0, targetBPM > 0 else { return 0 }
            let ratio = min(sourceBPM, targetBPM) / max(sourceBPM, targetBPM)
            return min(1, max(0, ratio * 0.35 + energyContinuity * 0.15
                              + vocalSafety * 0.15 + keySafety * 0.2
                              + phraseSafety * 0.1 + loudnessSafety * 0.05))
        case .crossfade:
            return energyContinuity * 0.35 + vocalSafety * 0.2 + keySafety * 0.2
                + phraseSafety * 0.1 + loudnessSafety * 0.15
        case .filterOut:
            return energyContinuity * 0.25 + vocalSafety * 0.4 + keySafety * 0.15
                + phraseSafety * 0.1 + loudnessSafety * 0.1
        case .hardCut:
            return (target.endsInSilence || source.endsInSilence) ? 0.65 : 0.25
        case .none:
            return 0
        }
    }

    private func harmonicCompatibility(source: NeuroTrackFeatures, target: NeuroTrackFeatures) -> Double {
        guard let sourceKey = source.key, let targetKey = target.key else { return 0.45 }
        if sourceKey == targetKey {
            return min(source.keyConfidence, target.keyConfidence)
        }
        let sourceParts = sourceKey.split(separator: "A")
        let targetParts = targetKey.split(separator: "A")
        guard sourceParts.count == 2, targetParts.count == 2,
              sourceParts[1] == targetParts[1],
              let sourceNumber = Int(sourceParts[0]),
              let targetNumber = Int(targetParts[0]) else { return 0.25 }
        let distance = abs(sourceNumber - targetNumber)
        return distance == 1 || distance == 11 ? 0.8 : 0.35
    }

    private func phraseCompatibility(source: NeuroTrackFeatures, target: NeuroTrackFeatures) -> Double {
        guard let outgoing = source.phraseMarkers.last,
              let incoming = target.phraseMarkers.first else { return 0.5 }
        return outgoing.isDrop == incoming.isDrop ? 1 : 0.45
    }

    private func loudnessCompatibility(source: NeuroTrackFeatures, target: NeuroTrackFeatures) -> Double {
        guard let sourceLoudness = source.loudnessLUFS,
              let targetLoudness = target.loudnessLUFS else { return 0.5 }
        return max(0, 1 - min(1, abs(sourceLoudness - targetLoudness) / 12))
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
        if source.endsInSilence || target.endsInSilence {
            candidates.append(candidate(
                .hardCut,
                source: source,
                target: target,
                duration: 0,
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
        let events = events(
            kind: kind,
            duration: duration,
            targetRate: targetRate,
            vocalConflict: source.vocalActivity * target.vocalActivity > 0.45
        )
        return NeuroTransitionPlan(
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
            usedFallback: false,
            events: events
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
            usedFallback: true,
            events: [
                NeuroTransitionEvent(
                    deck: .outgoing,
                    kind: .volume,
                    startSeconds: 0,
                    endSeconds: settings.crossfadeSeconds,
                    fromValue: 1,
                    toValue: 0
                ),
                NeuroTransitionEvent(
                    deck: .incoming,
                    kind: .volume,
                    startSeconds: 0,
                    endSeconds: settings.crossfadeSeconds,
                    fromValue: 0,
                    toValue: 1
                )
            ]
        )
    }

    private func events(
        kind: NeuroTransitionKind,
        duration: Double,
        targetRate: Double,
        vocalConflict: Bool
    ) -> [NeuroTransitionEvent] {
        guard duration > 0 else { return [] }
        var result = [
            NeuroTransitionEvent(
                deck: .outgoing,
                kind: .volume,
                startSeconds: 0,
                endSeconds: duration,
                fromValue: 1,
                toValue: 0
            ),
            NeuroTransitionEvent(
                deck: .incoming,
                kind: .volume,
                startSeconds: 0,
                endSeconds: duration,
                fromValue: 0,
                toValue: 1
            )
        ]
        if kind == .beatmatch || kind == .filterOut {
            result.append(NeuroTransitionEvent(
                deck: .outgoing,
                kind: .bassCut,
                startSeconds: duration * 0.45,
                endSeconds: duration * 0.65,
                fromValue: 0,
                toValue: 1
            ))
            result.append(NeuroTransitionEvent(
                deck: .incoming,
                kind: .lowPassSweep,
                startSeconds: 0,
                endSeconds: duration * 0.5,
                fromValue: 1_200,
                toValue: 20_000
            ))
        }
        if vocalConflict || kind == .filterOut {
            result.append(NeuroTransitionEvent(
                deck: .outgoing,
                kind: .highPassSweep,
                startSeconds: duration * 0.2,
                endSeconds: duration,
                fromValue: 20,
                toValue: 4_500
            ))
        }
        if targetRate != 1 {
            result.append(NeuroTransitionEvent(
                deck: .incoming,
                kind: .rateRamp,
                startSeconds: duration * 0.75,
                endSeconds: duration,
                fromValue: targetRate,
                toValue: 1
            ))
        }
        return result
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
