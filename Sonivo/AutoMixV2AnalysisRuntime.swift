// Path: Sonivo/AutoMixV2AnalysisRuntime.swift
//
// Analyzes the current/next track pair for MixPlanner plans + TrackProfiles.
// Runs when AutoMix V2 ownership is on OR when live PlayerCore is in
// AutoMix Mashup mode — so each mashup transition can be pair-specific
// without enabling DualDeck V2 ownership.

import Foundation
import MixModels
import MixPlanner
import Observation
import TrackAnalysis
import TrackSource

@Observable
@MainActor
final class AutoMixV2AnalysisRuntime {
    static let shared = AutoMixV2AnalysisRuntime()
    private let analyzer: TrackAnalyzer
    private let yandexClient = AutoMixV2YandexDownloadClient()
    private let yandexSource: YandexTrackSource?
    private let trackCache: TrackFileCache?
    private var observerTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var observedPair = ""
    private var plannedPair = ""
    private(set) var currentProfile: TrackProfile?
    private(set) var nextProfile: TrackProfile?
    private(set) var transitionPlan: MixModels.TransitionPlan?
    private(set) var pipelineStatus = "Ожидание воспроизведения"
    private(set) var lastError: String?

    private init() {
        let directory = (try? TrackAnalyzer.defaultStorageDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("profiles", isDirectory: true)
        analyzer = TrackAnalyzer(storageDirectory: directory)
        if let cache = try? TrackFileCache(directory: TrackFileCache.defaultDirectory()) {
            trackCache = cache
            yandexSource = YandexTrackSource(client: yandexClient, cache: cache, maximumParallelDownloads: 2)
        } else {
            trackCache = nil
            yandexSource = nil
        }
    }

    func install() {
        guard observerTask == nil else { return }
        observerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshPairIfNeeded()
                do { try await ContinuousClock().sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func recalculateCurrent() {
        let track = AutoMixV2Runtime.shared.currentTrack ?? PlayerCore.shared.currentTrack
        guard let track else { return }
        let id = trackID(for: track)
        analysisTask?.cancel()
        transitionPlan = nil; plannedPair = ""; observedPair = ""
        pipelineStatus = "Перезапуск анализа"
        analysisTask = Task { @MainActor [weak self] in
            guard let self, let id else { return }
            try? await analyzer.removeProfile(for: id)
            refreshPairIfNeeded()
        }
    }

    func plan(for currentID: TrackID, nextID: TrackID) -> MixModels.TransitionPlan? {
        let key = pairKey(currentID, nextID)
        guard plannedPair == key else { return nil }
        return transitionPlan
    }

    func status(for currentID: TrackID, nextID: TrackID) -> String {
        plannedPair == pairKey(currentID, nextID) && transitionPlan != nil
            ? "План перехода готов" : pipelineStatus
    }

    /// True when we should analyse the pair for mashup / V2 planning.
    private var shouldAnalyse: Bool {
        AutoMixEngineSelectionStore.shared.isV2Enabled
            || PlayerCore.shared.transitionMode == .automix
    }

    private func refreshPairIfNeeded() {
        guard shouldAnalyse else {
            if !observedPair.isEmpty || transitionPlan != nil || currentProfile != nil {
                observedPair = ""
                plannedPair = ""
                transitionPlan = nil
                currentProfile = nil
                nextProfile = nil
                pipelineStatus = "Ожидание воспроизведения"
            }
            return
        }

        let useV2Queue = AutoMixEngineSelectionStore.shared.isV2Enabled
            && AutoMixV2Runtime.shared.currentTrack != nil
        let current: Track
        let queue: [Track]
        if useV2Queue, let v2 = AutoMixV2Runtime.shared.currentTrack {
            current = v2
            queue = AutoMixV2Runtime.shared.playbackQueue
        } else if let legacy = PlayerCore.shared.currentTrack {
            current = legacy
            queue = PlayerCore.shared.queue
        } else {
            transitionPlan = nil; plannedPair = ""; pipelineStatus = "Ожидание воспроизведения"
            return
        }

        guard let currentID = trackID(for: current) else {
            pipelineStatus = "Нет ID трека для анализа"
            return
        }

        let index = queue.firstIndex(where: { $0.id == current.id })
        let next = index.flatMap { $0 + 1 < queue.count ? queue[$0 + 1] : nil }
        let nextID = next.flatMap(trackID)
        let key = currentID.raw + "|" + (nextID?.raw ?? "")
        guard key != observedPair else { return }

        observedPair = key
        plannedPair = ""
        transitionPlan = nil
        currentProfile = nil
        nextProfile = nil
        lastError = nil
        analysisTask?.cancel()

        // Mashup needs real BPM/grid for beatmatch — allow download when AutoMix Mashup is on.
        let allowDownload = AutoMixEngineSelectionStore.shared.isV2Enabled
            || PlayerCore.shared.transitionMode == .automix
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            pipelineStatus = allowDownload ? "Анализ / подготовка BPM пары" : "Анализ текущего трека"
            do {
                let currentFile = try await self.resolveFile(for: current, id: currentID, allowDownload: allowDownload)
                let rawA = try await analyzer.profile(for: currentID, fileURL: currentFile)
                let a = await TrackProfileEnricher.enrich(rawA, fileURL: currentFile)
                guard !Task.isCancelled, observedPair == key else { return }
                currentProfile = a
                guard let next, let nextID else {
                    pipelineStatus = "Следующего трека нет"
                    return
                }
                pipelineStatus = "Анализ следующего трека"
                let nextFile = try await self.resolveFile(for: next, id: nextID, allowDownload: allowDownload)
                let rawB = try await analyzer.profile(for: nextID, fileURL: nextFile)
                let b = await TrackProfileEnricher.enrich(rawB, fileURL: nextFile)
                guard !Task.isCancelled, observedPair == key else { return }
                nextProfile = b
                let settings = MixSettings(
                    mode: .automix,
                    crossfadeSeconds: MashupBlendScheduler.defaultPreferredBlendSec,
                    skipTransitionsWithinAlbum: false,
                    dontCutEndings: false,
                    loudnessNormalization: false,
                    targetLUFS: -14
                )
                let plan = MixPlanner.plan(
                    from: a, to: b,
                    aMeta: metadata(for: current, id: currentID),
                    bMeta: metadata(for: next, id: nextID),
                    settings: settings
                )
                guard !Task.isCancelled, observedPair == key else { return }
                transitionPlan = plan
                plannedPair = pairKey(currentID, nextID)
                pipelineStatus = plan.type == .none
                    ? "План запретил музыкальный переход; будет кроссфейд"
                    : "План перехода готов · \(plan.archetype.rawValue)"
            } catch {
                guard observedPair == key, !Self.isCancellation(error) else { return }
                transitionPlan = nil
                plannedPair = ""
                lastError = String(describing: error)
                // Profiles may still be partially filled; live mashup falls back to heuristics.
                pipelineStatus = "Эвристика mashup (анализ недоступен)"
            }
        }
    }

    private func resolveFile(for track: Track, id: TrackID, allowDownload: Bool) async throws -> URL {
        if !track.isStream { return track.url }
        if let cached = PlayerCore.shared.findLocalOrCachedAudioFile(for: track) {
            return cached
        }
        if let trackCache, let url = try? await trackCache.fileURL(for: id) {
            return url
        }
        guard allowDownload else {
            throw TrackSourceError.trackUnavailable
        }
        guard let yandexSource else { throw TrackSourceError.invalidResponse }
        await yandexClient.register(metadata(for: track, id: id))
        return try await yandexSource.localFileURL(for: id)
    }

    private func pairKey(_ currentID: TrackID, _ nextID: TrackID) -> String { currentID.raw + "|" + nextID.raw }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private func metadata(for track: Track, id: TrackID) -> TrackMeta {
        TrackMeta(
            id: id,
            title: track.title,
            artist: track.artist,
            albumID: track.album.isEmpty ? nil : track.album,
            durationSec: track.duration,
            artworkURL: track.coverURL.flatMap(URL.init(string:))
        )
    }

    private func trackID(for track: Track) -> TrackID? {
        if track.isStream {
            guard let raw = YandexMusicService.ymId(fromFileName: track.fileName) else { return nil }
            return TrackID(raw: raw)
        }
        return TrackID(raw: track.id.uuidString)
    }
}
