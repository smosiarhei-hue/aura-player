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
        guard let decoded = diskCached(key: key) else { return nil }
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

    /// Analyse a remote stream (no local file, e.g. a Yandex Music track).
    /// A small quality copy is downloaded once so the exact same DSP pipeline
    /// used for local files can extract a real BPM, beat grid, key and
    /// structure instead of AutoMix falling back to a generic energy blend.
    /// The cache key is the stable per-track UUID, so the analysis is reused
    /// across app launches without re-downloading anything.
    func analysis(trackID: UUID, streamURL: URL) async -> TrackAnalysis? {
        let key = Self.streamCacheKey(for: trackID)
        if let value = memory[key] { return value }
        if let decoded = diskCached(key: key) {
            memory[key] = decoded
            return decoded
        }
        if let running = inFlight[key] { return await running.value }

        let task = Task.detached(priority: .utility) {
            await Self.computeFromRemote(trackID: trackID, remoteURL: streamURL)
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

    private func diskCached(key: String) -> TrackAnalysis? {
        let file = Self.cacheDirectory().appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              decoded.analysisVersion == TrackAnalysis.currentVersion else { return nil }
        return decoded
    }

    nonisolated private static func compute(trackID: UUID, url: URL) async -> TrackAnalysis? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let features = await AutoMixDSP.features(for: url) else { return nil }

        let beats = BeatAnalyzer.analyze(features: features)
        let key = KeyDetector.detect(chroma: features.chroma)
        let structure = StructureAnalyzer.analyze(features: features, downbeats: beats.downbeats)

        let avgEnergy = structure.energyCurve.isEmpty ? 0.7 : Double(structure.energyCurve.reduce(0, +) / Float(structure.energyCurve.count))
        let introEndSec = structure.introEnd ?? 8.0
        let outroStartSec = structure.outroStart ?? max(0, features.duration - 18.0)

        let introSection = MusicSection(start: 0, end: introEndSec, type: .intro, energy: 0.4)
        let outroSection = MusicSection(start: outroStartSec, end: features.duration, type: .outro, energy: 0.5)

        return TrackAnalysis(
            trackID: trackID.uuidString,
            duration: features.duration,
            bpm: beats.bpm,
            bpmConfidence: Double(beats.confidence),
            musicalKey: key.displayName,
            keyConfidence: Double(key.confidence),
            energy: avgEnergy,
            danceability: avgEnergy > 0.6 ? 0.85 : 0.60,
            introStart: 0,
            introEnd: introEndSec,
            outroStart: outroStartSec,
            outroEnd: features.duration,
            firstBeat: beats.beatGrid.first,
            lastBeat: beats.beatGrid.last,
            beats: beats.beatGrid,
            downbeats: beats.downbeats,
            sections: [introSection, outroSection],
            silenceRegions: [],
            vocalRegions: [],
            instrumentalRegions: [],
            drops: [],
            buildUps: [],
            energyCurve: structure.energyCurve,
            analysisVersion: TrackAnalysis.currentVersion
        )
    }

    /// Downloads a remote stream to a private temp file and reuses the exact
    /// same decode/feature pipeline as local files. The temp file is removed
    /// as soon as the analysis is done, regardless of success or failure.
    nonisolated private static func computeFromRemote(trackID: UUID, remoteURL: URL) async -> TrackAnalysis? {
        guard let localURL = await downloadToTemp(remoteURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: localURL) }
        return await compute(trackID: trackID, url: localURL)
    }

    nonisolated private static func downloadToTemp(_ url: URL) async -> URL? {
        guard let (tempFile, _) = try? await URLSession.shared.download(from: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMixAnalysis-" + UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.moveItem(at: tempFile, to: destination)
            return destination
        } catch {
            return nil
        }
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

    nonisolated private static func streamCacheKey(for trackID: UUID) -> String {
        "stream-" + trackID.uuidString + "-v" + String(TrackAnalysis.currentVersion)
    }
}
