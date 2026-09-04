import Foundation

// MARK: - Background analysis warm-up for the AutoMix lookahead
//
// The AutoMix lookahead (`SmartNextTrackSelector`) deliberately scores only
// tracks whose analysis is ALREADY cached, and the only thing that ever
// filled that cache in bulk was the local library warm-up. For streamed
// queues (Yandex rotor, charts, Mood Radio) that meant the lookahead almost
// never saw two analysed tracks at once, so both the smart pick and the
// Gemini plan silently degraded to "plain next track + generic local plan" -
// the whole measured-audio pipeline existed but never got any data in time.
//
// This warmer fills the gap the way the design intended: a bounded,
// low-priority, strictly serialised analysis pass over the closest upcoming
// tracks. It never runs more than one analysis at a time, so it cannot
// compete with realtime playback or with the transition planning of the pair
// that is actually about to be mixed, and it analyses each track at most
// once per app run. Results are also mirrored into
// `AutoMixAnalysisSnapshot` so main-actor consumers (Mood Radio ranking) can
// score on measured values.
actor AutoMixLookaheadWarmer {
    static let shared = AutoMixLookaheadWarmer()

    /// Tracks already analysed (or attempted) in this app run.
    private var handled: Set<UUID> = []
    private var pending: [Track] = []
    private var worker: Task<Void, Never>?

    /// Never queue up more than a couple of tracks ahead: further than that
    /// the queue usually changes before the analysis would be useful.
    private static let maxPending = 4

    private init() {}

    /// Schedule a warm-up pass. Safe to call from anywhere and as often as
    /// the lookahead runs - duplicate and already analysed tracks are
    /// filtered out.
    nonisolated func schedule(current: Track?, upcoming: [Track], limit: Int = 3) {
        Task(priority: .utility) {
            await self.enqueue(current: current, upcoming: upcoming, limit: limit)
        }
    }

    private func enqueue(current: Track?, upcoming: [Track], limit: Int) {
        var wanted: [Track] = []

        // The current track matters most: without its analysis the lookahead
        // cannot score anything at all.
        if let current, !handled.contains(current.id) {
            wanted.append(current)
        }
        for track in upcoming {
            guard wanted.count < limit + 1 else { break }
            guard !handled.contains(track.id) else { continue }
            guard !wanted.contains(where: { $0.id == track.id }) else { continue }
            wanted.append(track)
        }
        guard !wanted.isEmpty else { return }

        for track in wanted {
            guard pending.count < Self.maxPending else { break }
            guard !pending.contains(where: { $0.id == track.id }) else { continue }
            pending.append(track)
        }

        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.drain()
            await self?.workerFinished()
        }
    }

    private func workerFinished() {
        worker = nil
        startWorkerIfNeeded()
    }

    private func drain() async {
        while !pending.isEmpty {
            let track = pending.removeFirst()
            guard !handled.contains(track.id) else { continue }
            handled.insert(track.id)

            if let cached = await TrackAnalysisService.shared.cachedAnalysis(for: track) {
                AutoMixAnalysisSnapshot.record(cached, for: track.id)
                continue
            }

            if let analysis = await TrackAnalysisService.shared.analysis(for: track) {
                AutoMixAnalysisSnapshot.record(analysis, for: track.id)
                SonivoDiagnostics.log(
                    "[AutoMix Warmup] analysed upcoming track: BPM \(analysis.bpm.map { String(format: "%.1f", $0) } ?? "—"), key \(analysis.musicalKey ?? "—")",
                    tag: "AUTOMIX"
                )
            }

            // Give playback, prebuffering and the real transition planning
            // priority between two warm-up runs.
            await Task.yield()
        }
    }
}
