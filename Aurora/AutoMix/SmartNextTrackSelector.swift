import Foundation

// MARK: - AutoMix smart next-track lookahead (offline vibe matcher)
//
// `peekNext` walks the queue in plain order (or shuffles randomly). For
// AutoMix mode this adds an optional, best-effort upgrade: scan a bounded
// lookahead window of upcoming queue tracks and, using ONLY analysis that
// is already cached (never triggering a fresh analysis run or download on
// this hot path — PlayerCore prewarms analysis in the background), score
// every candidate by the same four dimensions a DJ feels:
//
//   1. Harmonic compatibility (Camelot wheel key mixing)
//   2. Tempo compatibility  (BPM close enough for the +/-6% stretch lock)
//   3. Energy / vibe        (dancefloor energy curve must not jump)
//   4. Beat confidence     (steady, detectable grids blend cleanly)
//
// The winner must clear a minimum bar; otherwise the plain queue order is
// kept. The online Wave (Yandex rotor) already supplies same-vibe tracks,
// so this matcher works fully offline on the downloaded/local library.
enum SmartNextTrackSelector {
    /// Bounded lookahead window — enough to find a real harmonic/vibe match
    /// without scanning the whole queue.
    private static let lookaheadCount = 10

    /// Minimum total score for a swap to be worth disrupting queue order.
    private static let acceptThreshold = 0.52

    struct ScoredCandidate: Sendable {
        let track: Track
        let score: Double
        let harmonic: Double
        let rhythm: Double
        let vibe: Double
    }

    /// Score a candidate pair publicly so UI can show match percentages.
    nonisolated static func score(current: TrackAnalysis, candidate: TrackAnalysis) -> (harmonic: Double, rhythm: Double, vibe: Double, total: Double) {
        let harmonic = TransitionPlanner.harmonicScore(source: current, target: candidate)

        let rhythm: Double
        if let s = current.bpm, let t = candidate.bpm, s > 0, t > 0 {
            rhythm = TransitionPlanner.rhythmScore(sourceBPM: s, targetBPM: t)
        } else {
            rhythm = 0.4
        }

        // Energy curve continuity: a 0.0↔1.0 jump (ballad into a banger)
        // feels broken no matter how well keys and tempi match.
        let energyDiff = abs(current.energy - candidate.energy)
        let energyScore = max(0, 1.0 - energyDiff * 1.8)

        // Danceability agreement (beat strength proxy): two driving tracks
        // or two flowing tracks mix more naturally than opposites.
        let danceDiff = abs((current.danceability ?? current.energy) - (candidate.danceability ?? candidate.energy))
        let danceScore = max(0, 1.0 - danceDiff)

        let vibe = energyScore * 0.65 + danceScore * 0.35

        // Confidence of the grids we are about to lock together.
        let confidence = min(max(current.bpmConfidence, 0.3), max(candidate.bpmConfidence, 0.3))

        let total = harmonic * 0.42 + rhythm * 0.33 + vibe * 0.20 + confidence * 0.05
        return (harmonic, rhythm, vibe, total)
    }

    /// Better AutoMix candidate than `fallback` among the next few queued
    /// tracks, using only already-cached analysis. Returns `nil` when
    /// nothing scores well enough or no candidate has cached analysis yet —
    /// callers keep `fallback` in that case.
    static func betterCandidate(
        current: Track,
        fallback: Track,
        upcoming: [Track]
    ) async -> Track? {
        guard let currentAnalysis = await TrackAnalysisService.shared.cachedAnalysis(for: current) else { return nil }

        let lookahead = upcoming.filter { $0.id != current.id }.prefix(lookaheadCount)

        var scored: [ScoredCandidate] = []
        for track in lookahead {
            if let analysis = await TrackAnalysisService.shared.cachedAnalysis(for: track) {
                let s = score(current: currentAnalysis, candidate: analysis)
                scored.append(ScoredCandidate(track: track, score: s.total,
                                              harmonic: s.harmonic, rhythm: s.rhythm, vibe: s.vibe))
            }
        }
        guard let winner = scored.max(by: { $0.score < $1.score }) else { return nil }

        // Also score the fallback so a queue-ordered track that already
        // fits well is not swapped out for a marginally "better" one.
        if let fallbackAnalysis = await TrackAnalysisService.shared.cachedAnalysis(for: fallback) {
            let fallbackScore = score(current: currentAnalysis, candidate: fallbackAnalysis).total
            if winner.score < fallbackScore + 0.06 { return nil }
        }

        guard winner.score >= acceptThreshold, winner.track.id != fallback.id else { return nil }
        return winner.track
    }

    /// Match percentage (0...1) for display in the upcoming-track card.
    static func matchPercent(current: TrackAnalysis?, candidate: TrackAnalysis?) -> Double? {
        guard let current, let candidate else { return nil }
        return score(current: current, candidate: candidate).total
    }
}
