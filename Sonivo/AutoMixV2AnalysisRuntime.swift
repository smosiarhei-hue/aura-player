// Path: Sonivo/AutoMixV2AnalysisRuntime.swift
//
// Analyzes the current/next track pair for MixPlanner plans + TrackProfiles.
// Runs when AutoMix V2 ownership is on OR when live PlayerCore is in
// AutoMix Mashup / Duet mode — so each mashup transition can be pair-specific
// without enabling DualDeck V2 ownership.

import AudioEngineCore
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
    private var stemPrepTask: Task<Void, Never>?
    private var observedPair = ""
    private var plannedPair = ""
    private(set) var currentProfile: TrackProfile?
    private(set) var nextProfile: TrackProfile?
    private(set) var transitionPlan: MixModels.TransitionPlan?
    private(set) var pipelineStatus = "Ожидание воспроизведения"
    /// Shown on the player while HTDemucs downloads or separates the next window.
    private(set) var stemStatus: String?
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

    /// Field 1133/1137: bake already materialized A/B while the observer was still
    /// on `bpm0` / `mood.scan` — profile those URLs so rates/loops lock before MIXING.
    /// Uses a dedicated bake token so the background observer cannot race `observedPair`
    /// and discard a finished profile (field 1137: silent ingest miss → bpm0 forever).
    @discardableResult
    func ingestBakeLocalPair(
        outgoing: Track,
        incoming: Track,
        outgoingFile: URL,
        incomingFile: URL
    ) async -> Bool {
        guard shouldAnalyse else {
            AutoMixSessionLog.shared.event("analysis.bake-local skip=disabled")
            return false
        }
        guard let currentID = trackID(for: outgoing),
              let nextID = trackID(for: incoming) else {
            AutoMixSessionLog.shared.event("analysis.bake-local skip=noTrackID")
            return false
        }
        let planMode = mixSettingsMode
        let key = currentID.raw + "|" + nextID.raw + "|" + planMode.rawValue
        if plannedPair == pairKey(currentID, nextID),
           let plan = transitionPlan, plan.type != .none,
           let a = currentProfile, a.bpm > 30,
           let b = nextProfile, b.bpm > 30 {
            AutoMixSessionLog.shared.event(
                String(format: "analysis.bake-local cached bpmA=%.0f bpmB=%.0f", a.bpm, b.bpm)
            )
            return true
        }
        // Cancel background pair work and wait so it releases any live AVAudioFile
        // handle before we re-open the same caches (field 1145 GenericObjCError 0).
        let previous = analysisTask
        analysisTask?.cancel()
        analysisTask = nil
        _ = await previous?.value
        let bakeToken = key
        observedPair = key
        plannedPair = ""
        lastError = nil
        pipelineStatus = "Анализ bake-local пары"
        var cleanup: [URL] = []
        defer {
            for url in cleanup {
                try? FileManager.default.removeItem(at: url)
            }
        }
        do {
            // Float32 CAF / private copy — never fight the live Automix deck.
            let safeOut = try Self.analysisSafeURL(outgoingFile)
            if let scratch = safeOut.cleanup { cleanup.append(scratch) }
            let safeIn = try Self.analysisSafeURL(incomingFile)
            if let scratch = safeIn.cleanup { cleanup.append(scratch) }

            let rawA = try await analyzer.profile(for: currentID, fileURL: safeOut.url)
            var a = await TrackProfileEnricher.enrich(rawA, fileURL: safeOut.url)
            a = await applyNeuralCue(to: a, track: outgoing, role: .outgoing)
            let rawB = try await analyzer.profile(for: nextID, fileURL: safeIn.url)
            var b = await TrackProfileEnricher.enrich(rawB, fileURL: safeIn.url)
            b = await applyNeuralCue(to: b, track: incoming, role: .incoming)
            // Publish profiles even if the observer raced — PlayerCore reads these next.
            currentProfile = a
            nextProfile = b
            observedPair = bakeToken
            let settings = MixSettings(
                mode: planMode == .duet ? .duet : .automix,
                crossfadeSeconds: MashupBlendScheduler.defaultPreferredBlendSec,
                skipTransitionsWithinAlbum: false,
                dontCutEndings: false,
                loudnessNormalization: false,
                targetLUFS: -14
            )
            let plan = MixPlanner.plan(
                from: a, to: b,
                aMeta: metadata(for: outgoing, id: currentID),
                bMeta: metadata(for: incoming, id: nextID),
                settings: settings
            )
            transitionPlan = plan
            plannedPair = pairKey(currentID, nextID)
            pipelineStatus = plan.type == .none
                ? "План запретил музыкальный переход; будет кроссфейд"
                : "План перехода готов · \(plan.archetype.rawValue) · A@\(String(format: "%.0f", a.mixOutSec))s"
            let ok = a.bpm > 30 && b.bpm > 30
            AutoMixSessionLog.shared.event(
                String(
                    format: "analysis.bake-local bpmA=%.0f bpmB=%.0f rateA=%.3f rateB=%.3f plan=%@ ok=%d",
                    a.bpm, b.bpm, plan.rateA, plan.rateB, plan.archetype.rawValue, ok ? 1 : 0
                )
            )
            // Profiles with BPM still unlock beatmatch even when MixPlanner declines.
            return ok
        } catch {
            if Self.isCancellation(error) {
                AutoMixSessionLog.shared.event("analysis.bake-local cancel")
                return false
            }
            lastError = String(describing: error)
            pipelineStatus = "Эвристика mashup (bake-local анализ недоступен)"
            let ns = error as NSError
            AutoMixSessionLog.shared.event(
                "analysis.bake-local fail \(error.localizedDescription) domain=\(ns.domain) code=\(ns.code)"
            )
            return false
        }
    }

    /// CAF / private copy for BPM analysis while the live deck holds the cache.
    private static func analysisSafeURL(_ fileURL: URL) throws -> (url: URL, cleanup: URL?) {
        let ext = fileURL.pathExtension.lowercased()
        let compressed = ["m4a", "mp3", "aac", "m4b", "mp4"].contains(ext)
        if compressed {
            // AVAssetReader path survives live-deck locks that kill AVAudioFile.
            let caf = try MidSideStemBaker.decodeCompressedToFloat32CAF(fileURL)
            return (caf, caf)
        }
        let copyExt = fileURL.pathExtension.isEmpty ? "caf" : fileURL.pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-bake-analyze-\(UUID().uuidString).\(copyExt)")
        do {
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return (copy, copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            // Last resort: openFloat32Source may still materialize a scratch CAF.
            let opened = try MidSideStemBaker.openFloat32Source(fileURL)
            return (opened.file.url, opened.scratch)
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
            || PlayerCore.shared.transitionMode == .duet
    }

    private var mixSettingsMode: MixModels.TransitionMode {
        switch PlayerCore.shared.transitionMode {
        case .duet: return .duet
        case .automix: return .automix
        case .crossfade: return .crossfade
        case .off, .gapless: return .off
        }
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
        // Include mode so Automix ↔ Duet switches re-plan the same pair.
        let key = currentID.raw + "|" + (nextID?.raw ?? "") + "|" + mixSettingsMode.rawValue
        guard key != observedPair else { return }

        observedPair = key
        plannedPair = ""
        transitionPlan = nil
        currentProfile = nil
        nextProfile = nil
        lastError = nil
        analysisTask?.cancel()
        stemPrepTask?.cancel()
        stemStatus = nil

        // Mashup / Duet needs real BPM/grid for beatmatch — allow download when those modes are on.
        let allowDownload = AutoMixEngineSelectionStore.shared.isV2Enabled
            || PlayerCore.shared.transitionMode == .automix
            || PlayerCore.shared.transitionMode == .duet
        let planMode = mixSettingsMode
        analysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            pipelineStatus = allowDownload ? "Анализ / подготовка BPM пары" : "Анализ текущего трека"
            if allowDownload, HTDemucsModelStore.shared.installedPackageURL() == nil {
                stemStatus = "HTDemucs · модель 0%"
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await HTDemucsModelStore.shared.prepare { fraction in
                            let message = "HTDemucs · модель \(Int((fraction * 100).rounded()))%"
                            Task { @MainActor in
                                if self.stemStatus?.hasPrefix("HTDemucs · модель") == true {
                                    self.stemStatus = message
                                }
                            }
                        }
                    } catch {
                        if self.stemStatus?.hasPrefix("HTDemucs · модель") == true {
                            let text = (error as? HTDemucsModelError)?.description ?? "нет сети, повторю"
                            SonivoDiagnostics.log("[HTDemucs] \(text)", tag: "AUDIO")
                            self.stemStatus = nil
                        }
                    }
                }
            }
            do {
                let currentFile = try await self.resolveFile(for: current, id: currentID, allowDownload: allowDownload)
                // Same live-deck lock as bake-local — profile a private CAF/copy.
                let safeOut = try Self.analysisSafeURL(currentFile)
                defer { if let scratch = safeOut.cleanup { try? FileManager.default.removeItem(at: scratch) } }
                let rawA = try await analyzer.profile(for: currentID, fileURL: safeOut.url)
                var a = await TrackProfileEnricher.enrich(rawA, fileURL: safeOut.url)
                // LRC / synced lyrics refine mixOut while the song plays (lab neuralAutomix).
                pipelineStatus = planMode == .duet ? "Duet · текст / neural cue…" : "Automix · текст / neural cue…"
                a = await self.applyNeuralCue(to: a, track: current, role: .outgoing)
                guard !Task.isCancelled, observedPair == key else { return }
                currentProfile = a
                guard let next, let nextID else {
                    pipelineStatus = "Следующего трека нет"
                    return
                }
                pipelineStatus = "Анализ следующего трека"
                let nextFile = try await self.resolveFile(for: next, id: nextID, allowDownload: allowDownload)
                let safeIn = try Self.analysisSafeURL(nextFile)
                defer { if let scratch = safeIn.cleanup { try? FileManager.default.removeItem(at: scratch) } }
                let rawB = try await analyzer.profile(for: nextID, fileURL: safeIn.url)
                var b = await TrackProfileEnricher.enrich(rawB, fileURL: safeIn.url)
                b = await self.applyNeuralCue(to: b, track: next, role: .incoming)
                guard !Task.isCancelled, observedPair == key else { return }
                nextProfile = b
                let settings = MixSettings(
                    mode: planMode == .duet ? .duet : .automix,
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
                    : "План перехода готов · \(plan.archetype.rawValue) · A@\(String(format: "%.0f", a.mixOutSec))s"
                AutoMixSessionLog.shared.event(
                    String(
                        format: "analysis.pair bpmA=%.0f bpmB=%.0f rateA=%.3f rateB=%.3f plan=%@",
                        a.bpm, b.bpm, plan.rateA, plan.rateB, plan.archetype.rawValue
                    )
                )
                if plan.type != .none {
                    let outFile = currentFile
                    let inFile = nextFile
                    stemPrepTask?.cancel()
                    let pairToken = key
                    stemPrepTask = Task { @MainActor [weak self] in
                        await HTDemucsMashupBake.prewarm(outgoingFile: outFile, incomingFile: inFile) { message in
                            Task { @MainActor in
                                guard self?.observedPair == pairToken else { return }
                                if message.hasPrefix("HTDemucs · скрыть") {
                                    SonivoDiagnostics.log("[HTDemucs] \(message)", tag: "AUDIO")
                                    self?.stemStatus = nil
                                    return
                                }
                                if message == "HTDemucs · готово" {
                                    self?.stemStatus = nil
                                    return
                                }
                                self?.stemStatus = message
                            }
                        }
                    }
                }
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

    /// Fuse energy analysis with Yandex LRC / synced lyrics (lab Whisper brain).
    private func applyNeuralCue(
        to profile: TrackProfile,
        track: Track,
        role: NeuralCueRole
    ) async -> TrackProfile {
        let lyrics = try? await LyricsService.shared.fetchLyrics(for: track)
        let transcript = AutomixLyricsBridge.transcript(from: lyrics)
        guard transcript != nil || !profile.energyCurve.isEmpty else { return profile }
        return NeuralAutomixCue.applying(to: profile, transcript: transcript, role: role)
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
