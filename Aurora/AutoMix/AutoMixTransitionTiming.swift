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

        // Target 2 to 4 bars (8 to 16 beats) for an authentic, crisp outro DJ blend (~5.5 - 7.5s)
        let maxBars = max(2.0, floor((sourceDur * 0.08) / bar))
        let targetBars = min(4.0, max(2.0, maxBars))
        return targetBars * bar
    }

    nonisolated static func musicalCueTime(
        strategy: TransitionStrategy,
        source: TrackAnalysis,
        duration: Double
    ) -> Double {
        // Strictly anchor to the outro (at least 90% of track duration or last 7-9 seconds)
        let minOutroCue = max(0, max(source.duration * 0.90, source.duration - 8.5))
        var candidate = max(minOutroCue, source.duration - duration)

        if strategy == .SILENCE_TRIM, let silence = source.trailingSilence {
            candidate = max(minOutroCue, silence.start - duration)
        } else if let vocalEnd = source.lastVocalEnd, vocalEnd >= minOutroCue {
            candidate = vocalEnd
        } else if source.outroStart >= minOutroCue {
            candidate = source.outroStart
        } else if let boundary = source.sections.last(where: {
            $0.end >= minOutroCue && $0.end <= source.duration - 3.5
        })?.end {
            candidate = boundary
        }

        if let downbeat = source.nearestDownbeat(to: candidate, tolerance: 2.0) {
            candidate = downbeat
        }
        let latestStart = max(minOutroCue, source.duration - 3.5)
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
