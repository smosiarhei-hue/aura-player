// Path: Aurora/AutoMix/AutoMixTransitionTiming.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func blendLength(
        for strategy: TransitionStrategy,
        source: TrackAnalysis,
        sourceDur: TimeInterval
    ) -> TimeInterval {
        let bar = (source.barDuration.flatMap { ($0 >= 1.0 && $0 <= 4.0) ? $0 : nil })
            ?? (source.bpm.flatMap { normalizedBPM($0) }.map { 240.0 / $0 })
            ?? 2.0

        // Always target 8 to 16 bars (32 to 64 beats) for an authentic DJ blend
        let maxBars = max(4.0, floor((sourceDur * 0.25) / bar))
        let targetBars: Double
        if maxBars >= 16.0 {
            targetBars = 16.0
        } else if maxBars >= 8.0 {
            targetBars = 8.0
        } else {
            targetBars = max(4.0, maxBars)
        }
        return targetBars * bar
    }

    nonisolated static func musicalCueTime(
        strategy: TransitionStrategy,
        source: TrackAnalysis,
        duration: Double
    ) -> Double {
        // Strictly anchor to the outro (at least 75% of track duration)
        let minOutroCue = max(0, source.duration * 0.75)
        var candidate = max(minOutroCue, source.duration - duration)

        if strategy == .SILENCE_TRIM, let silence = source.trailingSilence {
            candidate = max(minOutroCue, silence.start - duration)
        } else if let vocalEnd = source.lastVocalEnd, vocalEnd >= minOutroCue {
            candidate = vocalEnd
        } else if source.outroStart >= minOutroCue {
            candidate = source.outroStart
        } else if let boundary = source.sections.last(where: {
            $0.end >= minOutroCue && $0.end <= source.duration - 4
        })?.end {
            candidate = boundary
        }

        if let downbeat = source.nearestDownbeat(to: candidate, tolerance: 3.5) {
            candidate = downbeat
        }
        let latestStart = max(minOutroCue, source.duration - 4.0)
        return min(latestStart, max(minOutroCue, candidate))
    }

    nonisolated static func phaseAlignedStart(
        cueTime: TimeInterval,
        blendDuration: TimeInterval,
        sourceRate: Double,
        targetRate: Double,
        source: TrackAnalysis,
        target: TrackAnalysis
    ) -> Double {
        let musicalEntry: Double = {
            if let instrumental = target.instrumentalRegions.first(where: { $0.start <= 12 && $0.duration >= 4 }) {
                return instrumental.start
            }
            if target.introEnd >= 2, target.introEnd <= 12 { return target.introEnd }
            if let downbeat = target.downbeats.first(where: { $0 >= 1 && $0 <= 12 }) { return downbeat }
            if let firstBeat = target.firstBeat, firstBeat >= 0, firstBeat <= 12 { return firstBeat }
            return min(8, max(2, target.duration * 0.03))
        }()

        guard let sourceBPM = normalizedBPM(source.bpm),
              let targetBPM = normalizedBPM(target.bpm) else {
            return musicalEntry
        }

        let sourcePeriod = 60 / sourceBPM / max(0.5, sourceRate)
        let targetPeriod = 60 / targetBPM / max(0.5, targetRate)
        guard sourcePeriod.isFinite, targetPeriod.isFinite, targetPeriod > 0 else {
            return musicalEntry
        }

        let handoffTime = cueTime + blendDuration * 0.52
        let sourcePhase = handoffTime.truncatingRemainder(dividingBy: sourcePeriod)
        let targetPhase = musicalEntry.truncatingRemainder(dividingBy: targetPeriod)
        var correction = sourcePhase - targetPhase
        if correction > targetPeriod / 2 { correction -= targetPeriod }
        if correction < -targetPeriod / 2 { correction += targetPeriod }
        return min(12, max(0, musicalEntry + correction))
    }
}
