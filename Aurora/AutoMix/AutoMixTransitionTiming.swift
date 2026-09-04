// Path: Aurora/AutoMix/AutoMixTransitionTiming.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func blendLength(
        for strategy: TransitionStrategy,
        source: TrackAnalysis,
        sourceDur: TimeInterval
    ) -> TimeInterval {
        let base: Double
        switch strategy {
        case .SILENCE_TRIM: base = 2
        case .VOCAL_CUT, .HARD_CUT, .DROP_SWITCH: base = 6
        case .ECHO_OUT, .FILTER_TRANSITION: base = 10
        case .BASS_SWAP, .BEAT_MATCH, .BEAT_MATCH_EQ: base = 16
        case .INSTRUMENTAL_OVERLAY, .LOOP_TRANSITION: base = 18
        default: base = 14
        }
        let limited = min(base, max(4, sourceDur * 0.30))
        guard let bar = source.barDuration, bar >= 1.2, bar <= 4 else {
            return limited
        }
        return min(24, max(4, (limited / bar).rounded() * bar))
    }

    nonisolated static func musicalCueTime(
        strategy: TransitionStrategy,
        source: TrackAnalysis,
        duration: Double
    ) -> Double {
        let latestStart = max(0, source.duration - 2)
        var candidate = max(0, source.duration - duration)

        if strategy == .SILENCE_TRIM, let silence = source.trailingSilence {
            candidate = max(0, silence.start - 0.5)
        } else if let vocalEnd = source.lastVocalEnd,
                  source.duration - vocalEnd >= duration * 0.65,
                  source.duration - vocalEnd <= 32 {
            candidate = vocalEnd
        } else if source.outroStart > 1,
                  source.duration - source.outroStart >= duration * 0.65,
                  source.duration - source.outroStart <= 36 {
            candidate = source.outroStart
        } else if let boundary = source.sections.last(where: {
            ($0.type == .chorus || $0.type == .verse || $0.type == .bridge) && $0.end <= source.duration - 2
        })?.end {
            candidate = max(candidate, boundary)
        }

        if let downbeat = source.nearestDownbeat(to: candidate, tolerance: 3.5) {
            candidate = downbeat
        }
        return min(latestStart, max(0, candidate))
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
