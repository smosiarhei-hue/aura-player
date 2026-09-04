// Path: Aurora/AutoMix/AutoMixTransitionValidation.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func sanitize(
        _ plan: TransitionPlan,
        sourceAnalysis: TrackAnalysis,
        targetAnalysis: TrackAnalysis
    ) -> TransitionPlan {
        let sourceDuration = max(8, sourceAnalysis.duration)
        let cue = min(max(0, plan.sourceTrack.transitionStart), max(0, sourceDuration - 2))
        let rawEnd = plan.sourceTrack.transitionEnd.isFinite ? plan.sourceTrack.transitionEnd : cue + 8
        let end = min(sourceDuration, max(cue + 2, rawEnd))
        let sourceRate = safeRate(plan.tempo.sourcePlaybackRate)
        let targetRate = safeRate(plan.tempo.targetPlaybackRate)
        let strategy = plan.strategy
        let actions = plan.actions.isEmpty
            ? actionEnvelopes(strategy: strategy, duration: end - cue)
            : plan.actions.filter {
                $0.time.isFinite && $0.duration.isFinite && $0.value.isFinite
                    && ($0.target == "source" || $0.target == "target")
            }
        let targetStart = phaseAlignedStart(
            cueTime: cue,
            blendDuration: end - cue,
            sourceRate: sourceRate,
            targetRate: targetRate,
            source: sourceAnalysis,
            target: targetAnalysis
        )
        let effects = TransitionEffects(
            reverbPreset: TransitionEffects.reverbPresets.contains(plan.effects.reverbPreset)
                ? plan.effects.reverbPreset
                : "plate"
        )

        return TransitionPlan(
            decision: TransitionDecisionInfo(
                transitionType: strategy.rawValue,
                confidence: min(1, max(0.1, plan.decision.confidence)),
                reason: plan.decision.reason
            ),
            sourceTrack: TransitionSourceTrackInfo(transitionStart: cue, transitionEnd: end),
            targetTrack: TransitionTargetTrackInfo(startPosition: targetStart),
            tempo: TransitionTempoInfo(
                targetBPM: normalizedBPM(targetAnalysis.bpm) ?? normalizedBPM(sourceAnalysis.bpm) ?? 120,
                sourcePlaybackRate: sourceRate,
                targetPlaybackRate: targetRate
            ),
            actions: actions,
            fallback: TransitionFallbackInfo(type: plan.fallback.type.isEmpty ? TransitionStrategy.ENERGY_BLEND.rawValue : plan.fallback.type),
            effects: effects
        )
    }

    nonisolated private static func safeRate(_ value: Double) -> Double {
        guard value.isFinite, value >= minStretch, value <= maxStretch else { return 1 }
        return value
    }
}
