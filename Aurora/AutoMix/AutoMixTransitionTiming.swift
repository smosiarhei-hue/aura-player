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

        // Real DJ Mashup transition duration across 8 to 16 musical bars (12.0s - 20.0s)
        // Provides authentic iOS 27 style harmonic mashup blending with beatmatched phrasing
        let barsCount: Double = (sourceDur > 100.0) ? 8.0 : 4.0
        let targetDuration = min(20.0, max(12.0, bar * barsCount))
        return targetDuration
    }

    nonisolated static func musicalCueTime(
        strategy: TransitionStrategy,
        source: TrackAnalysis,
        duration: Double
    ) -> Double {
        // Musical phrase mashup cue: anchor 16 to 24s before track end or at outro phrase
        let minOutroCue = max(0, source.duration - max(duration + 4.0, 24.0))
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

        if let downbeat = source.nearestDownbeat(to: candidate, tolerance: 2.0) {
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
