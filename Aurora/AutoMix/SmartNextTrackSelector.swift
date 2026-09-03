import Foundation

// MARK: - AutoMix smart next-track lookahead
//
// `peekNext` walks the queue in plain order (or shuffles randomly). For
// AutoMix mode this adds an optional, best-effort upgrade: scan a bounded
// lookahead window of upcoming queue tracks and, using ONLY analysis that
// is already cached (never triggering a fresh analysis run or download),
// ask `TransitionPlanner.bestAutoMixCandidate` whether one of them mashes
// up with the current track (harmonic key + tempo) better than the plain
// next track in the queue.
//
// This never blocks or replaces the plain queue order: callers should keep
// their safe fallback set first and only swap in the result of this scan
// while nothing has committed yet to the fallback (no active transition
// plan, no planning in flight, no pre-buffered stream) - that guard is what
// avoids the previous race between a smart-pick swap and an
// already-scheduled plan/prebuffer for a different track.
enum SmartNextTrackSelector {
    /// Bounded lookahead window - enough to find a real harmonic match
    /// without scanning the whole queue or waiting on uncached analysis.
    private static let lookaheadCount = 8

    /// Better AutoMix candidate than `fallback` among the next few queued
    /// tracks, using only already-cached track analysis. Returns `nil` when
    /// nothing scores well enough or no candidate has cached analysis yet -
    /// callers should keep `fallback` in that case.
    static func betterCandidate(
        current: Track,
        fallback: Track,
        upcoming: [Track]
    ) async -> Track? {
        guard let currentAnalysis = await TrackAnalysisService.shared.cachedAnalysis(for: current) else { return nil }

        let lookahead = upcoming.filter { $0.id != current.id }.prefix(lookaheadCount)

        var candidates: [(track: Track, analysis: TrackAnalysis)] = []
        for track in lookahead {
            if let analysis = await TrackAnalysisService.shared.cachedAnalysis(for: track) {
                candidates.append((track, analysis))
            }
        }
        guard !candidates.isEmpty else { return nil }

        guard let winner = TransitionPlanner.bestAutoMixCandidate(current: currentAnalysis, candidates: candidates),
              winner.id != fallback.id else { return nil }
        return winner
    }
}
