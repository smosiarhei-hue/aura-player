// Path: Aurora/AutoMix/AutoMixTransitionTiming.swift

import Foundation

extension TransitionPlanner {
    nonisolated static func blendLength(
        for strategy: TransitionStrategy,
        source: TrackAnalysis,
        sourceDur: TimeInterval
    ) -> TimeInterval {
        let bar = (source.barDuration.flatMap { ($0 >= 1.0 && $0 <= 3.0) ? $0 : nil })
            ?? (source.bpm.flatMap { normalizedBPM($0) }.map { 240.0 / $0 })
            ?? 2.0

        // Punchy, vocal-safe DJ transition duration (2.8 - 3.5s)
        // Prevents muddy long vocal overlap where lyrics clash.
        let targetDuration = min(3.5, max(2.8, bar * 1.5))
        return targetDuration
    }

    nonisolated static func musicalCueTime(
        strategy: TransitionStrategy,
        source: TrackAnalysis,
        duration: Double
    ) -> Double {
        // Strictly anchor to the outro (at least 92% of track duration or last 6.5 seconds)
        let minOutroCue = max(0, max(source.duration * 0.92, source.duration - 6.5))
        var candidate = max(minOutroCue, source.duration - duration)

        if strategy == .SILENCE_TRIM, let silence = source.trailingSilence {
            candidate = max(minOutroCue, silence.start - duration)
        } else if let vocalEnd = source.lastVocalEnd, vocalEnd >= minOutroCue {
            candidate = vocalEnd
        } else if source.outroStart >= minOutroCue {
            candidate = source.outroStart
        } else if let boundary = source.sections.last(where: {
            $0.end >= minOutroCue && $0.end <= source.duration - 2.5
        })?.end {
            candidate = boundary
        }

        if let downbeat = source.nearestDownbeat(to: candidate, tolerance: 1.5) {
            candidate = downbeat
        }
        let latestStart = max(minOutroCue, source.duration - 2.5)
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
        // Natural musical intro: incoming track always starts from 0.0 (the natural beginning of the song).
        // Seeking forward into the middle (introEnd, instrumental) cuts off the track's intro,
        // triggers vocal-on-vocal clashes with the outgoing song, and stalls streaming buffers.
        _ = cueTime
        _ = blendDuration
        _ = sourceRate
        _ = targetRate
        _ = source
        _ = target
        return 0.0
    }
}
