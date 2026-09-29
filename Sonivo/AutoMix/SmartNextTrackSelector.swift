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
//
// Because the scan itself is cache-only, it also kicks off a bounded,
// low-priority warm-up (`AutoMixLookaheadWarmer`) for the closest upcoming
// tracks. Without it, streamed queues never had analysed candidates in time
// and the smart pick could only ever fire for the local library.
enum SmartNextTrackSelector {
    /// Bounded lookahead window - enough to find a real harmonic match
    /// without scanning the whole queue or waiting on uncached analysis.
    private static let lookaheadCount = 8

    /// How many of the closest upcoming tracks are worth analysing ahead of
    /// time in the background.
    private static let warmupCount = 3

    /// Better AutoMix candidate than `fallback` among the next few queued
    /// tracks, using only already-cached track analysis. Returns `nil` when
    /// nothing scores well enough or no candidate has cached analysis yet -
    /// callers should keep `fallback` in that case.
    static func betterCandidate(
        current: Track,
        fallback: Track,
        upcoming: [Track]
    ) async -> Track? {
        let lookahead = Array(upcoming.filter { $0.id != current.id }.prefix(lookaheadCount))

        // Keep the analysis cache warm so the next runs of this scan (and the
        // AI transition plan) actually have measured audio to work with.
        AutoMixLookaheadWarmer.shared.schedule(
            current: current,
            upcoming: Array(lookahead.prefix(warmupCount)),
            limit: warmupCount
        )

        guard let currentAnalysis = await TrackAnalysisService.shared.cachedAnalysis(for: current) else { return nil }
        AutoMixAnalysisSnapshot.record(currentAnalysis, for: current.id)

        var candidates: [(track: Track, analysis: TrackAnalysis)] = []
        for track in lookahead {
            if let analysis = await TrackAnalysisService.shared.cachedAnalysis(for: track) {
                AutoMixAnalysisSnapshot.record(analysis, for: track.id)
                candidates.append((track, analysis))
            }
        }
        guard !candidates.isEmpty else { return nil }

        guard let winner = TransitionPlanner.bestAutoMixCandidate(current: currentAnalysis, candidates: candidates),
              winner.id != fallback.id else { return nil }
        return winner
    }
}
