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
    private var observedSelectionRevision: UUID?
    private var plannedPair = ""
    private var analysisGeneration = UUID()
    private(set) var currentProfile: TrackProfile?
    private(set) var nextProfile: TrackProfile?
    private var storedTransitionPlan: MixModels.TransitionPlan?
    private(set) var transitionPlan: MixModels.TransitionPlan? {
        get { selectionIsCurrent(observedSelectionRevision) ? storedTransitionPlan : nil }
        set { storedTransitionPlan = newValue }
    }
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
        analysisGeneration = UUID()
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
        let selectionRevision = observedSelectionRevision
        if let selectionRevision {
            let selected = PlayerCore.shared.automaticNextSelection()
            guard PlayerCore.shared.currentTrack?.id == outgoing.id,
                  selected.track?.id == incoming.id,
                  selected.revision == selectionRevision else { return false }
        }
        let planMode = mixSettingsMode
        let key = currentID.raw + "|" + nextID.raw + "|" + planMode.rawValue
        if observedPair == key, plannedPair == pairKey(currentID, nextID),
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
        guard observedPair == key else { return false }
        let request = UUID()
        analysisGeneration = request
        var published = false
        defer {
            // A cancelled bake must not leave this pair marked observed forever;
            // allow the observer to retry it without touching a newer request.
            if !published, Task.isCancelled, analysisGeneration == request, observedPair == key {
                observedPair = ""
            }
        }
        let previous = analysisTask
        analysisTask?.cancel()
        analysisTask = nil
        _ = await previous?.value
        // Awaiting the old task yields the main actor: a new pair may have
        // arrived (including A→B→A). Do not overwrite its state.
        guard !Task.isCancelled, analysisGeneration == request,
              observedPair == key, mixSettingsMode == planMode, shouldAnalyse,
              selectionIsCurrent(selectionRevision) else { return false }
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
            let safeOut = try await Self.prepareAnalysisURL(outgoingFile)
            if let scratch = safeOut.cleanup { cleanup.append(scratch) }
            let safeIn = try await Self.prepareAnalysisURL(incomingFile)
            if let scratch = safeIn.cleanup { cleanup.append(scratch) }

            let rawA = try await analyzer.profile(for: currentID, fileURL: safeOut.url)
            var a = await TrackProfileEnricher.enrich(rawA, fileURL: safeOut.url)
            a = await applyNeuralCue(to: a, track: outgoing, role: .outgoing)
            let rawB = try await analyzer.profile(for: nextID, fileURL: safeIn.url)
            var b = await TrackProfileEnricher.enrich(rawB, fileURL: safeIn.url)
            b = await applyNeuralCue(to: b, track: incoming, role: .incoming)
            // A track/queue/mode change can happen while decode and enrichment await.
            // Never publish a stale pair into the current player's plan.
            guard !Task.isCancelled, analysisGeneration == request,
                  observedPair == bakeToken, mixSettingsMode == planMode, shouldAnalyse,
                  selectionIsCurrent(selectionRevision) else { return false }
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
            published = true
            pipelineStatus = plan.type == .none
                ? "План запретил переход; трек доиграет до конца"
                : (plan.type == .crossfade && planMode == .automix
                   ? "Безопасный кроссфейд · \(plan.reason)"
                   : "План перехода готов · \(plan.archetype.rawValue) · A@\(String(format: "%.0f", a.mixOutSec))s")
            let ok = a.bpm > 30 && b.bpm > 30
            AutoMixSessionLog.shared.event(
                String(
                    format: "analysis.bake-local bpmA=%.0f bpmB=%.0f rateA=%.3f rateB=%.3f plan=%@ type=%@ reason=%@ ok=%d",
                    a.bpm, b.bpm, plan.rateA, plan.rateB, plan.archetype.rawValue,
                    plan.type.rawValue, plan.reason, ok ? 1 : 0
                )
            )
            // Profiles with BPM still unlock beatmatch even when MixPlanner declines.
            return ok
        } catch {
            guard analysisGeneration == request, observedPair == bakeToken,
                  mixSettingsMode == planMode, shouldAnalyse,
                  selectionIsCurrent(selectionRevision) else { return false }
            if Self.isCancellation(error) || Task.isCancelled {
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

    /// Preparing a private analysis file can decode an entire compressed track.
    /// Keep that work off the main actor and remove scratch files if cancelled.
    private static func prepareAnalysisURL(_ fileURL: URL) async throws -> (url: URL, cleanup: URL?) {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try Self.analysisSafeURL(fileURL)
            if Task.isCancelled {
                if let scratch = result.cleanup { try? FileManager.default.removeItem(at: scratch) }
                throw CancellationError()
            }
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        if Task.isCancelled {
            if let scratch = result.cleanup { try? FileManager.default.removeItem(at: scratch) }
            throw CancellationError()
        }
        return result
    }

    /// CAF / private copy for BPM analysis while the live deck holds the cache.
    nonisolated private static func analysisSafeURL(_ fileURL: URL) throws -> (url: URL, cleanup: URL?) {
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
        guard plannedPair == key,
              observedPair == key + "|" + mixSettingsMode.rawValue,
              selectionIsCurrent(observedSelectionRevision) else { return nil }
        return transitionPlan
    }

    private func selectionIsCurrent(_ revision: UUID?) -> Bool {
        guard let revision else { return true } // V2 owns its separate queue.
        return PlayerCore.shared.automaticNextSelectionIsCurrent(revision)
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
                analysisGeneration = UUID()
                analysisTask?.cancel()
                stemPrepTask?.cancel()
                observedPair = ""
                observedSelectionRevision = nil
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
        let next: Track?
        let selectionRevision: UUID?
        if useV2Queue, let v2 = AutoMixV2Runtime.shared.currentTrack {
            current = v2
            let queue = AutoMixV2Runtime.shared.playbackQueue
            let index = queue.firstIndex(where: { $0.id == current.id })
            next = index.flatMap { $0 + 1 < queue.count ? queue[$0 + 1] : nil }
            selectionRevision = nil
        } else if let legacy = PlayerCore.shared.currentTrack {
            current = legacy
            let selection = PlayerCore.shared.automaticNextSelection()
            next = selection.track
            selectionRevision = selection.revision
        } else {
            transitionPlan = nil; plannedPair = ""; pipelineStatus = "Ожидание воспроизведения"
            return
        }

        guard let currentID = trackID(for: current) else {
            pipelineStatus = "Нет ID трека для анализа"
            return
        }

        let nextID = next.flatMap(trackID)
        // Include mode so Automix ↔ Duet switches re-plan the same pair.
        let key = currentID.raw + "|" + (nextID?.raw ?? "") + "|" + mixSettingsMode.rawValue
        guard key != observedPair || selectionRevision != observedSelectionRevision else { return }

        let request = UUID()
        let diagnosticID = String(request.uuidString.prefix(8))
        analysisGeneration = request
        observedPair = key
        observedSelectionRevision = selectionRevision
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
            let modelInstalled = HTDemucsModelStore.shared.installedPackageURL() != nil
            AutoMixSessionLog.shared.event(
                "demucs.pair id=\(diagnosticID) A=\(String(current.id.uuidString.prefix(6))) B=\(next.map { String($0.id.uuidString.prefix(6)) } ?? "-") modelInstalled=\(modelInstalled ? 1 : 0) downloadAllowed=\(allowDownload ? 1 : 0)"
            )
            if allowDownload, !modelInstalled {
                stemStatus = "HTDemucs · модель 0%"
                AutoMixSessionLog.shared.event("demucs.download.start id=\(diagnosticID)")
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
                        AutoMixSessionLog.shared.event("demucs.download.ready id=\(diagnosticID)")
                    } catch {
                        AutoMixSessionLog.shared.event(
                            "demucs.download.failed id=\(diagnosticID) reason=\(HTDemucsMashupBake.diagnosticError(error))"
                        )
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
                let safeOut = try await Self.prepareAnalysisURL(currentFile)
                defer { if let scratch = safeOut.cleanup { try? FileManager.default.removeItem(at: scratch) } }
                let rawA = try await analyzer.profile(for: currentID, fileURL: safeOut.url)
                var a = await TrackProfileEnricher.enrich(rawA, fileURL: safeOut.url)
                // LRC / synced lyrics refine mixOut while the song plays (lab neuralAutomix).
                pipelineStatus = planMode == .duet ? "Duet · текст / neural cue…" : "Automix · текст / neural cue…"
                a = await self.applyNeuralCue(to: a, track: current, role: .outgoing)
                guard !Task.isCancelled, analysisGeneration == request, observedPair == key,
                      selectionIsCurrent(selectionRevision) else { return }
                currentProfile = a
                guard let next, let nextID else {
                    pipelineStatus = "Следующего трека нет"
                    AutoMixSessionLog.shared.event("demucs.prewarm.skipped id=\(diagnosticID) reason=no-next-track")
                    return
                }
                pipelineStatus = "Анализ следующего трека"
                let nextFile = try await self.resolveFile(for: next, id: nextID, allowDownload: allowDownload)
                let safeIn = try await Self.prepareAnalysisURL(nextFile)
                defer { if let scratch = safeIn.cleanup { try? FileManager.default.removeItem(at: scratch) } }
                let rawB = try await analyzer.profile(for: nextID, fileURL: safeIn.url)
                var b = await TrackProfileEnricher.enrich(rawB, fileURL: safeIn.url)
                b = await self.applyNeuralCue(to: b, track: next, role: .incoming)
                guard !Task.isCancelled, analysisGeneration == request, observedPair == key,
                      selectionIsCurrent(selectionRevision) else { return }
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
                guard !Task.isCancelled, analysisGeneration == request, observedPair == key,
                      selectionIsCurrent(selectionRevision) else { return }
                transitionPlan = plan
                plannedPair = pairKey(currentID, nextID)
                pipelineStatus = plan.type == .none
                    ? "План запретил переход; трек доиграет до конца"
                    : (plan.type == .crossfade && planMode == .automix
                       ? "Безопасный кроссфейд · \(plan.reason)"
                       : "План перехода готов · \(plan.archetype.rawValue) · A@\(String(format: "%.0f", a.mixOutSec))s")
                AutoMixSessionLog.shared.event(
                    String(
                        format: "analysis.pair bpmA=%.0f bpmB=%.0f rateA=%.3f rateB=%.3f plan=%@ type=%@ reason=%@",
                        a.bpm, b.bpm, plan.rateA, plan.rateB, plan.archetype.rawValue,
                        plan.type.rawValue, plan.reason
                    )
                )
                // Structured, path-free pair evidence survives even when the verbose
                // session log is disabled. Never export titles or raw error strings.
                let fallbackCause: String
                if plan.type != .crossfade { fallbackCause = "none" }
                else if plan.reason.contains("темпы") { fallbackCause = "tempo" }
                else if plan.reason.contains("Тональный конфликт") { fallbackCause = "key" }
                else if plan.reason.contains("сетки") || plan.reason.contains("сетка") { fallbackCause = "grid" }
                else if plan.reason.contains("фазовое") { fallbackCause = "phase" }
                else if plan.reason.contains("короткий трек") { fallbackCause = "short" }
                else if plan.reason.contains("не предназначен") { fallbackCause = "unmixable" }
                else { fallbackCause = "other" }
                AutoMixSessionLog.shared.event(String(
                    format: "demucs.plan id=%@ type=%@ cause=%@ bpmA=%.2f bpmB=%.2f bpmConfA=%.2f bpmConfB=%.2f downConfA=%.2f downConfB=%.2f",
                    diagnosticID, plan.type.rawValue, fallbackCause, a.bpm, b.bpm,
                    a.confidence.bpm, b.confidence.bpm, a.confidence.downbeats, b.confidence.downbeats
                ))
                if plan.type != .none && plan.type != .crossfade {
                    let outFile = currentFile
                    let inFile = nextFile
                    stemPrepTask?.cancel()
                    let pairToken = key
                    // Most AutoMix plans enter B after the cold intro. Prewarm
                    // that actual window instead of always separating 0...36s,
                    // which misses a late cue plus its blend and bake pad.
                    let incomingWindow: (start: Double, duration: Double)
                    var outgoingWindow: (start: Double, duration: Double)?
                    if planMode == .automix {
                        let cue = MashupBlendScheduler.clampAutomixIncomingCue(
                            preferred: plan.bInStartSec, incomingDur: b.durationSec
                        )
                        incomingWindow = HTDemucsWindowMixer.incomingPrewarmWindow(
                            cue: cue, blend: MashupTransitionExecutor.durationSeconds(for: plan)
                        )
                        let plannedDuration = MashupTransitionExecutor.durationSeconds(for: plan)
                        if (plan.type == .beatmatchedShort || plan.type == .beatmatchedLong),
                           let plannedCue = MashupBlendScheduler.plannedCueIfUsable(
                               cue: plan.aOutStartSec, duration: a.durationSec, blend: plannedDuration,
                               outgoingRate: Double(plan.rateA)
                           ) {
                            outgoingWindow = HTDemucsWindowMixer.incomingPrewarmWindow(
                                cue: plannedCue, blend: plannedDuration
                            )
                        }
                    } else {
                        incomingWindow = (0, HTDemucsMashupBake.prewarmSeconds)
                    }
                    let selectedOutgoingWindow = outgoingWindow
                    stemPrepTask = Task { @MainActor [weak self] in
                        await HTDemucsMashupBake.prewarm(
                            outgoingFile: outFile, incomingFile: inFile,
                            outgoingWindowStart: selectedOutgoingWindow?.start,
                            outgoingWindowSeconds: selectedOutgoingWindow?.duration ?? HTDemucsMashupBake.prewarmSeconds,
                            incomingWindowStart: incomingWindow.start,
                            incomingWindowSeconds: incomingWindow.duration,
                            onDiagnostic: { message in
                                Task { @MainActor in
                                    AutoMixSessionLog.shared.event("demucs.\(message) id=\(diagnosticID)")
                                }
                            }
                        ) { message in
                            Task { @MainActor in
                                guard self?.analysisGeneration == request, self?.observedPair == pairToken,
                                      self?.selectionIsCurrent(selectionRevision) == true else { return }
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
                } else {
                    AutoMixSessionLog.shared.event(
                        "demucs.prewarm.skipped id=\(diagnosticID) reason=plan-\(plan.type.rawValue)"
                    )
                }
            } catch {
                guard analysisGeneration == request, observedPair == key, !Task.isCancelled,
                      selectionIsCurrent(selectionRevision),
                      !Self.isCancellation(error) else { return }
                transitionPlan = nil
                plannedPair = ""
                lastError = String(describing: error)
                AutoMixSessionLog.shared.event(
                    "demucs.prewarm.skipped id=\(diagnosticID) reason=analysis-failed error=\(HTDemucsMashupBake.diagnosticError(error))"
                )
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
