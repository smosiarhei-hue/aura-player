import Foundation

// MARK: - Main-actor mirror of measured track analysis
//
// `TrackAnalysisService` is an actor, so main-actor code cannot read measured
// BPM / key / energy synchronously. Mood Radio ranking is exactly such code:
// `extractVector` runs inside synchronous scoring loops, which is why it used
// to guess a track's character from keywords in its title ("remix", "chill",
// "sad") even though the DSP had already measured the real thing.
//
// This tiny main-actor mirror closes that gap. It never analyses, downloads
// or decodes anything by itself: it only mirrors analysis that is ALREADY in
// the service's memory/disk cache (filled by the library warm-up and by
// `AutoMixLookaheadWarmer`), so synchronous callers can use measured values
// when they exist and fall back to heuristics when they do not.
@MainActor
final class AutoMixAnalysisSnapshot {
    static let shared = AutoMixAnalysisSnapshot()

    private var storage: [UUID: TrackAnalysis] = [:]
    private var insertionOrder: [UUID] = []
    private var refreshing: Set<UUID> = []

    /// Plenty for a Mood Radio session, small enough to stay cheap.
    private static let maxEntries = 500

    private init() {}

    // MARK: - Synchronous reads

    func analysis(for track: Track) -> TrackAnalysis? {
        storage[track.id]
    }

    func analysis(for trackID: UUID) -> TrackAnalysis? {
        storage[trackID]
    }

    // MARK: - Filling the mirror

    func store(_ analysis: TrackAnalysis, for trackID: UUID) {
        if storage[trackID] == nil {
            insertionOrder.append(trackID)
            if insertionOrder.count > Self.maxEntries {
                let oldest = insertionOrder.removeFirst()
                storage.removeValue(forKey: oldest)
            }
        }
        storage[trackID] = analysis
        refreshing.remove(trackID)
    }

    /// Fire-and-forget store from any isolation (analysis warm-up runs off the
    /// main actor).
    nonisolated static func record(_ analysis: TrackAnalysis, for trackID: UUID) {
        Task { @MainActor in
            shared.store(analysis, for: trackID)
        }
    }

    /// Pull whatever is already cached for these tracks into the mirror.
    /// Cache-only and bounded, so it is safe to await right before ranking a
    /// freshly fetched queue.
    func refreshFromCache(_ tracks: [Track], limit: Int = 40) async {
        var inspected = 0
        for track in tracks {
            guard inspected < limit else { break }
            guard storage[track.id] == nil else { continue }
            inspected += 1
            if let analysis = await TrackAnalysisService.shared.cachedAnalysis(for: track) {
                store(analysis, for: track.id)
            }
        }
    }

    /// Best-effort single-track refresh for synchronous callers: never blocks,
    /// never analyses, and asks at most once per track.
    func requestCacheRefresh(for track: Track) {
        guard storage[track.id] == nil, !refreshing.contains(track.id) else { return }
        refreshing.insert(track.id)
        let trackID = track.id
        Task { [weak self] in
            let cached = await TrackAnalysisService.shared.cachedAnalysis(for: track)
            guard let self else { return }
            if let cached {
                self.store(cached, for: trackID)
            } else {
                self.refreshing.remove(trackID)
            }
        }
    }
}

// MARK: - Measured feature vector

extension TrackVector {
    /// Build a mood vector from the MEASURED analysis of a track, using the
    /// heuristic vector only for what the DSP cannot measure (acousticness)
    /// and for low-confidence measurements.
    ///
    /// Mapping (all normalised to 0...1):
    ///   tempo        <- measured BPM, 60...180 BPM
    ///   energy       <- measured average RMS energy
    ///   valence      <- detected key mode (major brighter than minor),
    ///                   weighted by key confidence
    ///   danceability <- measured beat confidence (steady pulse == groove)
    ///   loudness     <- median of the measured energy curve (perceived
    ///                   loudness / compression rather than peak energy)
    ///   acousticness <- heuristic, pulled down when the track has a strong
    ///                   steady machine-like beat
    ///
    /// Stays main-actor isolated (the project builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, so `TrackVector.init` is
    /// main-actor isolated too). All call sites - Mood Radio ranking and the
    /// smart selector - already run on the main actor.
    static func measured(
        _ analysis: TrackAnalysis,
        fallback: TrackVector
    ) -> TrackVector {
        // Tempo
        var tempo = fallback.tempo
        if let bpm = analysis.bpm, bpm > 0, analysis.bpmConfidence >= 0.20 {
            let normalized = (bpm - 60.0) / 120.0
            let weight = min(1.0, max(0.0, analysis.bpmConfidence * 1.5))
            tempo = fallback.tempo + (normalized - fallback.tempo) * weight
        }

        // Energy
        let energy = analysis.energy.isFinite
            ? min(1.0, max(0.0, analysis.energy))
            : fallback.energy

        // Valence from the detected mode
        var valence = fallback.valence
        if let key = analysis.musicalKey, analysis.keyConfidence >= 0.20 {
            let isMinor = key.lowercased().contains("min") || key.hasSuffix("m")
            let target = isMinor ? 0.25 : 0.75
            let weight = min(1.0, max(0.0, analysis.keyConfidence * 1.4))
            valence = fallback.valence + (target - fallback.valence) * weight
        }

        // Danceability from the measured pulse
        let danceability = analysis.danceability ?? (0.30 + energy * 0.55)

        // Loudness from the measured energy curve
        var loudness = energy * 0.9
        if !analysis.energyCurve.isEmpty {
            let sorted = analysis.energyCurve.sorted()
            loudness = Double(sorted[sorted.count / 2])
        }

        // Acousticness: not directly measurable - keep the heuristic guess,
        // but a strong steady beat is a good argument against "acoustic".
        var acousticness = fallback.acousticness
        if analysis.hasSteadyBeat {
            acousticness = min(acousticness, 0.40 - 0.20 * (danceability - 0.5))
        }

        return TrackVector(
            tempo: tempo,
            energy: energy,
            valence: valence,
            acousticness: acousticness,
            danceability: danceability,
            loudness: loudness
        )
    }
}
