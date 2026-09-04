import Foundation

// MARK: - Pair-aware transition plan sanitising
//
// `TransitionPlanner.sanitize(_:sourceAnalysis:targetAnalysis:)` must be able
// to throw away an unusable AI plan and answer with a full local plan
// instead - but it only receives the two analyses, not the two tracks, so it
// had to call `planLocalFallback` with two throwaway `UUID()` values.
//
// Every deliberately "individual" detail of a local plan (blend length,
// reverb character, envelope depth, strategy tie-break) is derived from a
// seed built out of the pair of track ids. Feeding that seed with random
// UUIDs quietly turned the intended behaviour - a stable, characterful
// transition per pair of tracks - into a different transition every time the
// same two tracks met again.
//
// This overload keeps the real pair identity in the loop:
//   * it validates the AI cue itself and seeds the local fallback with the
//     actual source/target track ids (stable per pair),
//   * it preserves an AI-chosen reverb character when that character is one
//     the audio engine actually knows,
//   * and it derives a stable, pair-specific character from the measured
//     audio when the AI sent something unknown.
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
        let cueUsable = cue.isFinite
            && end.isFinite
            && cue >= 0
            && cue <= sourceAnalysis.duration + 1
            && end > cue

        guard cueUsable else {
            SonivoDiagnostics.log(
                "[AutoMix] Plan unusable (cue \(cue), end \(end)) - local DSP plan for this exact pair",
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
            // The planner actually chose a character for this pair - honour it.
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

    /// Reverb character for the outgoing tail, chosen from the measured audio
    /// of THIS pair and stable across runs: short bright tails for upbeat
    /// club material (the kick has to stay readable), long lush tails for
    /// slow or quiet material.
    nonisolated static func stableReverbPreset(
        sourceTrackID: UUID,
        sourceAnalysis: TrackAnalysis,
        targetTrackID: UUID,
        targetAnalysis: TrackAnalysis
    ) -> String {
        let energy = (sourceAnalysis.energy + targetAnalysis.energy) / 2
        let bpm = sourceAnalysis.bpm ?? targetAnalysis.bpm ?? 120

        let bright = ["plate", "smallRoom", "mediumRoom", "mediumChamber"]
        let lush = ["mediumHall", "largeHall", "largeRoom", "largeChamber", "cathedral"]
        let pool = (energy >= 0.55 || bpm >= 122) ? bright : lush

        let seed = pairSeed(
            sourceTrackID: sourceTrackID,
            targetTrackID: targetTrackID,
            salt: 2
        )
        return pool[Int(seed % UInt64(pool.count))]
    }

    /// Deterministic per-pair seed (FNV-1a over both track ids plus a salt),
    /// so the same two tracks always get the same character, and different
    /// pairs get different ones.
    nonisolated static func pairSeed(
        sourceTrackID: UUID,
        targetTrackID: UUID,
        salt: Int
    ) -> UInt64 {
        let material = sourceTrackID.uuidString + "|" + targetTrackID.uuidString + "|" + String(salt)
        var hash: UInt64 = 1469598103934665603
        for byte in material.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return hash
    }
}
