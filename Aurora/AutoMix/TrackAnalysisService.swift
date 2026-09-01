import Foundation

// MARK: - Analysis orchestration and cache
//
// Analysis costs seconds per track, so it runs off the main actor in detached
// tasks and the result is cached on disk. Local files are keyed by file
// identity (name, size, modification date); Yandex streams are analysed once
// by downloading a compact economical copy to a temporary file, which is
// deleted right after decoding - only the cached JSON stays. The cache key
// includes the analyser version, so a new algorithm or an edited file
// invalidates the entry automatically.

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
    private var ymInFlight: [String: Task<TrackAnalysis?, Never>] = [:]

    /// Upper bound for the temporary analysis download of a streamed track.
    private static let maxStreamDownloadBytes = 20 * 1024 * 1024

    private init() {}

    // MARK: - Public API

    /// Already analysed result, from memory or disk. Never blocks on decoding.
    func cached(for url: URL) -> TrackAnalysis? {
        let key = Self.cacheKey(for: url)
        if let value = memory[key] { return value }
        return Self.loadFromDisk(key: key).map { value in
            memory[key] = value
            return value
        }
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

    /// Analyse any track - local file or Yandex stream. Streams are resolved,
    /// downloaded as a compact copy, decoded and cleaned up. This is what makes
    /// AutoMix decisions real for the streaming catalogue instead of running on
    /// invented placeholder data.
    func analysis(for track: Track) async -> TrackAnalysis? {
        let url = track.url
        if !track.isStream, FileManager.default.fileExists(atPath: url.path) {
            return await analysis(trackID: track.id, url: url)
        }

        let ymID = Self.ymTrackID(from: track)
        guard !ymID.isEmpty else { return nil }

        let key = "ym-\(ymID)-v\(TrackAnalysis.currentVersion)"
        if let value = memory[key] { return value }
        if let value = Self.loadFromDisk(key: key) {
            memory[key] = value
            return value
        }
        if let running = ymInFlight[key] { return await running.value }

        let trackID = track.id
        let task = Task.detached(priority: .utility) { [key] in
            await Self.computeStream(trackID: trackID, ymID: ymID, cacheKey: key)
        }
        ymInFlight[key] = task
        let result = await task.value
        ymInFlight[key] = nil

        if let result {
            memory[key] = result
            Self.writeToDisk(result, key: key)
        }
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

    // MARK: - Stream decoding

    nonisolated private static func ymTrackID(from track: Track) -> String {
        let raw = track.streamUrlString ?? track.fileName
        return raw
            .replacingOccurrences(of: "ym_", with: "")
            .replacingOccurrences(of: ".mp3", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func computeStream(trackID: UUID, ymID: String, cacheKey: String) async -> TrackAnalysis? {
        guard let info = try? await YandexMusicService.shared.getStreamInfo(
            for: ymID,
            preferredQuality: .economical
        ) else {
            SonivoDiagnostics.log("[AutoMix] Stream analysis: could not resolve \(ymID)", tag: "AUTOMIX")
            return nil
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoMixStreamAnalysis", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(cacheKey + ".bin")

        defer { try? FileManager.default.removeItem(at: destination) }

        guard let (temp, response) = try? await URLSession.shared.download(from: info.url) else {
            SonivoDiagnostics.log("[AutoMix] Stream analysis: download failed for \(ymID)", tag: "AUTOMIX")
            return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > 0, size <= maxStreamDownloadBytes, response.expectedContentLength <= Int64(maxStreamDownloadBytes) else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            return nil
        }

        guard let analysis = await compute(trackID: trackID, url: destination) else { return nil }
        SonivoDiagnostics.log(
            "[AutoMix] Stream analysis ready: \(ymID) BPM \(analysis.bpm.map { String(format: "%.1f", $0) } ?? "—"), key \(analysis.musicalKey ?? "—")",
            tag: "AUTOMIX"
        )
        return analysis
    }

    // MARK: - Internals

    private func store(_ analysis: TrackAnalysis, key: String) {
        memory[key] = analysis
        Self.writeToDisk(analysis, key: key)
    }

    nonisolated private static func loadFromDisk(key: String) -> TrackAnalysis? {
        let file = cacheDirectory().appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              decoded.analysisVersion == TrackAnalysis.currentVersion else { return nil }
        return decoded
    }

    nonisolated private static func writeToDisk(_ analysis: TrackAnalysis, key: String) {
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        let file = cacheDirectory().appendingPathComponent(key + ".json")
        try? data.write(to: file, options: .atomic)
    }

    nonisolated private static func compute(trackID: UUID, url: URL) async -> TrackAnalysis? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let features = await AutoMixDSP.features(for: url) else { return nil }

        let beats = BeatAnalyzer.analyze(features: features)
        let key = KeyDetector.detect(chroma: features.chroma)
        let structure = StructureAnalyzer.analyze(features: features, downbeats: beats.downbeats)

        let avgEnergy = structure.energyCurve.isEmpty ? 0.5 : Double(structure.energyCurve.reduce(0, +) / Float(structure.energyCurve.count))
        let introEndSec = structure.introEnd ?? min(8.0, features.duration * 0.15)
        let outroStartSec = structure.outroStart ?? max(0, features.duration - 18.0)

        let drops = structure.cuePoints.filter { $0.kind == .preDrop }.map(\.time)

        // Danceability is derived from the measured beat confidence - strong
        // pulse means danceable, no pulse means we honestly do not know.
        let danceability: Double? = beats.confidence > 0.2
            ? 0.4 + 0.6 * Double(beats.confidence)
            : nil

        return TrackAnalysis(
            trackID: trackID.uuidString,
            duration: features.duration,
            bpm: beats.bpm,
            bpmConfidence: Double(beats.confidence),
            musicalKey: key.confidence > 0.15 ? key.displayName : nil,
            keyConfidence: Double(key.confidence),
            energy: avgEnergy,
            danceability: danceability,
            introStart: 0,
            introEnd: introEndSec,
            outroStart: outroStartSec,
            outroEnd: features.duration,
            firstBeat: beats.beatGrid.first,
            lastBeat: beats.beatGrid.last,
            beats: beats.beatGrid,
            downbeats: beats.downbeats,
            sections: structure.sections,
            silenceRegions: structure.silenceRegions,
            vocalRegions: structure.vocalRegions,
            instrumentalRegions: structure.instrumentalRegions,
            drops: drops,
            buildUps: structure.buildUps,
            energyCurve: structure.energyCurve,
            analysisVersion: TrackAnalysis.currentVersion
        )
    }

    nonisolated private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
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
