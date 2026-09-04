// Path: Aurora/AutoMix/TransitionPlanSanitizer.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func sanitize(
        _ plan: TransitionPlan,
        sourceTrackID: UUID,
        sourceAnalysis: TrackAnalysis,
        targetTrackID: UUID,
        targetAnalysis: TrackAnalysis
    ) -> TransitionPlan {
        let cue = plan.sourceTrack.transitionStart
        let end = plan.sourceTrack.transitionEnd
        let cueIsUsable = cue.isFinite
            && end.isFinite
            && cue >= 0
            && cue <= sourceAnalysis.duration + 1
            && end > cue

        guard cueIsUsable else {
            SonivoDiagnostics.log(
                "[AutoMix] Plan unusable (cue \(cue), end \(end)); rebuilding locally for the measured pair",
                tag: "AUTOMIX"
            )
            return planLocalFallback(
                sourceTrackID: sourceTrackID,
                sourceAnalysis: sourceAnalysis,
                targetTrackID: targetTrackID,
                targetAnalysis: targetAnalysis
            )
        }

        var result = sanitize(
            plan,
            sourceAnalysis: sourceAnalysis,
            targetAnalysis: targetAnalysis
        )

        if TransitionEffects.reverbPresets.contains(plan.effects.reverbPreset) {
            result.effects.reverbPreset = plan.effects.reverbPreset
        } else {
            result.effects.reverbPreset = stableReverbPreset(
                sourceTrackID: sourceTrackID,
                sourceAnalysis: sourceAnalysis,
                targetTrackID: targetTrackID,
                targetAnalysis: targetAnalysis
            )
        }
        return result
    }

    nonisolated static func stableReverbPreset(
        sourceTrackID: UUID,
        sourceAnalysis: TrackAnalysis,
        targetTrackID: UUID,
        targetAnalysis: TrackAnalysis
    ) -> String {
        chooseReverbPreset(
            source: sourceAnalysis,
            target: targetAnalysis,
            seed: pairSeed(
                sourceTrackID: sourceTrackID,
                targetTrackID: targetTrackID,
                salt: 2
            )
        )
    }
}
