// Path: Aurora/AutoMixV2AnalysisRuntime.swift

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
    private var observerTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var observedPair = ""
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
            yandexSource = YandexTrackSource(client: yandexClient, cache: cache, maximumParallelDownloads: 2)
        } else { yandexSource = nil }
    }
    func install() {
        guard observerTask == nil else { return }
        observerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshPairIfNeeded()
                do { try await ContinuousClock().sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func recalculateCurrent() {
        guard let track = AutoMixV2Runtime.shared.currentTrack else { return }
        let id = trackID(for: track); analysisTask?.cancel()
        analysisTask = Task { @MainActor [weak self] in
            guard let self, let id else { return }
            try? await analyzer.removeProfile(for: id)
            observedPair = ""; refreshPairIfNeeded()
        }
    }
    private func refreshPairIfNeeded() {
        guard AutoMixEngineSelectionStore.shared.isV2Enabled,
              let current = AutoMixV2Runtime.shared.currentTrack,
              let currentID = trackID(for: current) else { return }
        let queue = AutoMixV2Runtime.shared.playbackQueue
        let index = queue.firstIndex(where: { $0.id == current.id })
        let next = index.flatMap { $0 + 1 < queue.count ? queue[$0 + 1] : nil }
        let key = currentID.raw + "|" + (next.flatMap(trackID)?.raw ?? "")
        guard key != observedPair else { return }
        observedPair = key; analysisTask?.cancel()
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            pipelineStatus = "Анализ текущего трека"; lastError = nil
            do {
                let currentFile = try await localFile(for: current, id: currentID)
                let rawA = try await analyzer.profile(for: currentID, fileURL: currentFile)
                let a = await Stage3ProfileEnricher.enrich(rawA, fileURL: currentFile)
                guard !Task.isCancelled, observedPair == key else { return }
                currentProfile = a; nextProfile = nil; transitionPlan = nil
                guard let next, let nextID = trackID(for: next) else {
                    pipelineStatus = "Профиль текущего трека готов"; lastError = nil; return
                }
                pipelineStatus = "Анализ следующего трека и тональности"
                let nextFile = try await localFile(for: next, id: nextID)
                let rawB = try await analyzer.profile(for: nextID, fileURL: nextFile)
                let b = await Stage3ProfileEnricher.enrich(rawB, fileURL: nextFile)
                guard !Task.isCancelled, observedPair == key else { return }
                nextProfile = b
                let settings = MixSettings(mode: .automix,
                                           crossfadeSeconds: PlayerCore.shared.crossfadeDuration,
                                           skipTransitionsWithinAlbum: true,
                                           dontCutEndings: false,
                                           loudnessNormalization: true,
                                           targetLUFS: -14)
                transitionPlan = MixPlanner.plan(from: a, to: b,
                                                 aMeta: metadata(for: current, id: currentID),
                                                 bMeta: metadata(for: next, id: nextID),
                                                 settings: settings)
                pipelineStatus = "Профили и музыкальный план готовы"; lastError = nil
            } catch {
                guard observedPair == key, !Self.isCancellation(error) else { return }
                lastError = String(describing: error); pipelineStatus = "Ошибка анализа"
            }
        }
    }
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
    private func localFile(for track: Track, id: TrackID) async throws -> URL {
        if !track.isStream { return track.url }
        guard let yandexSource else { throw TrackSourceError.invalidResponse }
        await yandexClient.register(metadata(for: track, id: id))
        return try await yandexSource.localFileURL(for: id)
    }
    private func metadata(for track: Track, id: TrackID) -> TrackMeta {
        TrackMeta(id: id, title: track.title, artist: track.artist,
                  albumID: track.album.isEmpty ? nil : track.album,
                  durationSec: track.duration,
                  artworkURL: track.coverURL.flatMap(URL.init(string:)))
    }
    private func trackID(for track: Track) -> TrackID? {
        if track.isStream {
            guard let raw = YandexMusicService.ymId(fromFileName: track.fileName) else { return nil }
            return TrackID(raw: raw)
        }
        return TrackID(raw: track.id.uuidString)
    }
}
