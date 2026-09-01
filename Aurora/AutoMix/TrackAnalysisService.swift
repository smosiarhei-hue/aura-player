import Foundation

// MARK: - Analysis orchestration and cache
//
// Analysis costs seconds per track, so it runs off the main actor in detached
// tasks and the result is cached on disk. The cache key includes the file
// identity (name, size, modification date) and the analyser version, so a new
// algorithm or an edited file invalidates the entry automatically.

nonisolated struct AnalysisRequest: Sendable {
    let trackID: UUID
    let url: URL

    init(trackID: UUID, url: URL) {
        self.trackID = trackID
        self.url = url
    }
}

actor TrackAnalysisService {
    static let shared = TrackAnalysisService()

    private var memory: [String: TrackAnalysis] = [:]
    private var inFlight: [String: Task<TrackAnalysis?, Never>] = [:]

    private init() {}

    // MARK: - Public API

    /// Already analysed result, from memory or disk. Never blocks on decoding.
    func cached(for url: URL) -> TrackAnalysis? {
        let key = Self.cacheKey(for: url)
        if let value = memory[key] { return value }

        let file = Self.cacheDirectory().appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              decoded.analysisVersion == TrackAnalysis.currentVersion else { return nil }
        memory[key] = decoded
        return decoded
    }

    /// Analyse the file if needed. Concurrent callers share one run.
    func analysis(trackID: UUID, url: URL) async -> TrackAnalysis? {
        if let value = cached(for: url) { return value }

        let key = Self.cacheKey(for: url)
        if let running = inFlight[key] { return await running.value }

        let task = Task.detached(priority: .utility) {
            await Self.compute(trackID: trackID, url: url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let result { store(result, key: key) }
        return result
    }

    /// Analyse everything that is not cached yet, a couple of files at a time,
    /// reporting 0...1 progress. Safe to call on a full library scan.
    func warmUp(
        _ requests: [AnalysisRequest],
        concurrency: Int = 2,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async {
        let pending = requests.filter { cached(for: $0.url) == nil }
        guard !pending.isEmpty else {
            onProgress?(1)
            return
        }

        var remaining = pending
        var completed = 0
        let batchSize = max(1, min(concurrency, 4))

        while !remaining.isEmpty {
            let batch = Array(remaining.prefix(batchSize))
            remaining.removeFirst(batch.count)

            await withTaskGroup(of: Void.self) { group in
                for request in batch {
                    group.addTask {
                        _ = await self.analysis(trackID: request.trackID, url: request.url)
                    }
                }
            }

            completed += batch.count
            onProgress?(Double(completed) / Double(pending.count))
        }
    }

    func clearCache() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory())
    }

    // MARK: - Internals

    private func store(_ analysis: TrackAnalysis, key: String) {
        memory[key] = analysis
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        let file = Self.cacheDirectory().appendingPathComponent(key + ".json")
        try? data.write(to: file, options: .atomic)
    }

    nonisolated private static func compute(trackID: UUID, url: URL) async -> TrackAnalysis? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let features = await AutoMixDSP.features(for: url) else { return nil }

        let beats = BeatAnalyzer.analyze(features: features)
        let key = KeyDetector.detect(chroma: features.chroma)
        let structure = StructureAnalyzer.analyze(features: features, downbeats: beats.downbeats)

        return TrackAnalysis(
            trackID: trackID,
            bpm: beats.bpm,
            beatConfidence: beats.confidence,
            beatGrid: beats.beatGrid,
            downbeats: beats.downbeats,
            key: key,
            camelotPosition: CamelotPosition(key: key).label,
            energyCurve: structure.energyCurve,
            introEnd: structure.introEnd,
            outroStart: structure.outroStart,
            cuePoints: structure.cuePoints,
            duration: features.duration,
            analysisVersion: TrackAnalysis.currentVersion
        )
    }

    nonisolated private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("AutoMixAnalysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func cacheKey(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let seed = url.lastPathComponent + "|" + String(size) + "|" + String(Int(modified))
            + "|v" + String(TrackAnalysis.currentVersion)

        var hash: UInt64 = 1469598103934665603
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 36)
    }
}
