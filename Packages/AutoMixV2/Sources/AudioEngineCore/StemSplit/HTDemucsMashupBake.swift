import AVFAudio
import CryptoKit
import Foundation

/// Separates the outro and intro while the song plays, then hands the mashup
/// decks a vocal CAF and an instrumental CAF. Without the model on disk this
/// returns nil and the caller keeps the mid/side bake.
public enum HTDemucsMashupBake {
    public static let prewarmSeconds: Double = 36

    /// Safe, path-free error categories for the user-exported session log.
    public static func diagnosticError(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let model = error as? HTDemucsModelError {
            switch model.description {
            case "мало места на iPhone": return "insufficient-storage"
            case "битая ссылка модели": return "invalid-model-url"
            case "модель скачалась не целиком": return "incomplete-download"
            case "модель не открылась": return "model-load-refused"
            case "окно перехода вне кэша": return "window-outside-cache"
            case "аудиофайл изменился": return "source-file-changed"
            default:
                return model.description.hasPrefix("файл модели ") ? "model-file-size-mismatch" : "model-error"
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "network-\(ns.code)" }
        if ns.domain == NSCocoaErrorDomain { return "cocoa-\(ns.code)" }
        return "other-error"
    }

    /// Classify a nil result without exposing paths or model data in field logs.
    /// This is a snapshot: preparation can change between the attempt and logging.
    public static func unavailableReason() async -> String {
        guard HTDemucsModelStore.shared.installedPackageURL() != nil else {
            return "model-not-installed"
        }
        if await HTDemucsRuntime.shared.loadWasRefused() {
            return "model-load-refused"
        }
        return "window-not-ready"
    }

    public static func prewarm(
        outgoingFile: URL,
        incomingFile: URL,
        incomingWindowStart: Double = 0,
        incomingWindowSeconds: Double = prewarmSeconds,
        onDiagnostic: @escaping @Sendable (String) -> Void = { _ in },
        onStatus: @escaping @Sendable (String) -> Void
    ) async {
        if await HTDemucsRuntime.shared.loadWasRefused() {
            onDiagnostic("prewarm.skipped reason=model-load-refused")
            return
        }
        onDiagnostic("prewarm.start")
        do {
            onStatus("HTDemucs · модель 0%")
            _ = try await HTDemucsModelStore.shared.prepare { fraction in
                onStatus("HTDemucs · модель \(Int(fraction * 100))%")
            }
            try Task.checkCancellation()
            onDiagnostic("prewarm.package-ready")
            onStatus("HTDemucs · компилирую")
            onDiagnostic("prewarm.model-load-start")
            try await HTDemucsRuntime.shared.prewarm(
                outgoingFile: outgoingFile,
                incomingFile: incomingFile,
                seconds: prewarmSeconds,
                incomingStart: incomingWindowStart,
                incomingSeconds: incomingWindowSeconds,
                onDiagnostic: onDiagnostic,
                onStatus: { status in
                    switch status {
                    case "HTDemucs · аутро": onDiagnostic("prewarm.outgoing-window")
                    case "HTDemucs · интро": onDiagnostic("prewarm.incoming-window")
                    default: break
                    }
                    onStatus(status)
                }
            )
            try Task.checkCancellation()
            onDiagnostic("prewarm.ready")
            onStatus("HTDemucs · готово")
        } catch is CancellationError {
            onDiagnostic("prewarm.cancelled")
            return
        } catch {
            let refused = await HTDemucsRuntime.shared.loadWasRefused()
            onDiagnostic("prewarm.failed reason=\(diagnosticError(error)) loadRefused=\(refused ? 1 : 0)")
            let text = (error as? HTDemucsModelError)?.description ?? error.localizedDescription
            // The player badge must not keep a Core ML path. The host logs this and clears it.
            onStatus("HTDemucs · скрыть · \(text)")
        }
    }

    /// Nil when the model is not on disk yet. Throws only when this task is cancelled.
    public static func stemPair(
        duet: Bool,
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        blendSec: Double,
        handoffProgress: Double,
        padSec: Double,
        landFadeSec: Double = 0,
        playbackRate: Double = 1,
        loopSec: Double = 0,
        echoDelaySec: Double = 0,
        onDiagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (outgoing: URL, incoming: URL)? {
        guard HTDemucsModelStore.shared.installedPackageURL() != nil else { return nil }
        let musical = min(MidSideStemBaker.maximumDurationSec, max(4, blendSec))
        let duration = min(MidSideStemBaker.maximumDurationSec, musical + max(0, padSec))
        // Duet ramps its rate differently; preserve that path.
        let rate = duet ? min(1.04, max(0.96, playbackRate)) : HTDemucsWindowMixer.automixBakeRate(playbackRate)
        let handoff = duet ? min(0.72, max(0.52, handoffProgress)) : min(0.92, max(0.35, handoffProgress))
        let fadeWall = landFadeSec > 0.25 ? landFadeSec : max(0.9, min(2.4, musical * 0.12))
        var landWall = musical * handoff
        if landWall > duration - 0.3 { landWall = max(fadeWall + 0.35, duration - 0.3) }
        // File position runs ahead of the clock while the deck is beatmatched.
        let landAt = landWall * rate
        let pair = try await HTDemucsRuntime.shared.materialize(
            duet: duet,
            outgoingURL: outgoingURL,
            incomingURL: incomingURL,
            cueA: cueA,
            cueB: cueB,
            duration: duration,
            landAt: landAt,
            fadeSec: fadeWall * rate,
            loopSec: loopSec,
            echoDelaySec: echoDelaySec,
            onDiagnostic: onDiagnostic
        )
        return pair
    }
}

public actor HTDemucsRuntime {
    public static let shared = HTDemucsRuntime()

    private var separator: CoreMLStemSeparator?
    private var modelLoad: (id: UUID, task: Task<CoreMLStemSeparator, Error>)?
    private var windows: [CachedWindow] = []
    private var jobs = 0
    /// Avoid repeated expensive failures, but retry later after transient errors.
    private var retryModelLoadAfter: Date?

    func loadWasRefused() -> Bool { retryModelLoadAfter.map { Date() < $0 } ?? false }

    /// Uses a finished window if prewarm is still separating. Otherwise separates the cue itself.
    func materialize(
        duet: Bool,
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        duration: Double,
        landAt: Double,
        fadeSec: Double,
        loopSec: Double,
        echoDelaySec: Double,
        onDiagnostic: @escaping @Sendable (String) -> Void
    ) async throws -> (outgoing: URL, incoming: URL)? {
        // Prewarm and materialization share the actor, but window() suspends
        // during inference. A busy prewarm is not a failure: allow it a bounded,
        // cancellation-aware runway to finish before falling back. The caller
        // starts this job ahead of the cue and retains its own live fallback.
        for _ in 0..<100 {
            guard jobs > 0 else { break }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        if jobs > 0 {
            let pair = try cachedPair(
                duet: duet,
                outgoingURL: outgoingURL,
                incomingURL: incomingURL,
                cueA: cueA,
                cueB: cueB,
                duration: duration,
                landAt: landAt,
                fadeSec: fadeSec,
                loopSec: loopSec,
                echoDelaySec: echoDelaySec
            )
            switch pair {
            case .some: onDiagnostic("cache.busy-hit")
            case .none: onDiagnostic("cache.busy-miss")
            }
            return pair
        }
        jobs += 1
        defer { jobs -= 1 }
        return try await bakePair(
            duet: duet,
            outgoingURL: outgoingURL,
            incomingURL: incomingURL,
            cueA: cueA,
            cueB: cueB,
            duration: duration,
            landAt: landAt,
            fadeSec: fadeSec,
            loopSec: loopSec,
            echoDelaySec: echoDelaySec,
            onDiagnostic: onDiagnostic
        )
    }

    func prewarm(
        outgoingFile: URL,
        incomingFile: URL,
        seconds: Double,
        incomingStart: Double,
        incomingSeconds: Double,
        onDiagnostic: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        // Actors are reentrant across await: without an explicit lease, rapid
        // skips can run several costly Core ML prewarms at the same time.
        while jobs > 0 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
        jobs += 1
        defer { jobs -= 1 }
        _ = try await model()
        onStatus("HTDemucs · аутро")
        _ = try await window(url: outgoingFile, startSec: outroStart(outgoingFile, seconds: seconds),
                             seconds: seconds, role: "outgoing", onDiagnostic: onDiagnostic)
        try Task.checkCancellation()
        onStatus("HTDemucs · интро")
        let start = incomingStart.isFinite ? max(0, incomingStart) : 0
        let length = incomingSeconds.isFinite ? min(44, max(4, incomingSeconds)) : seconds
        _ = try await window(url: incomingFile, startSec: start, seconds: length,
                             role: "incoming", onDiagnostic: onDiagnostic)
    }

    private func cachedPair(
        duet: Bool,
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        duration: Double,
        landAt: Double,
        fadeSec: Double,
        loopSec: Double,
        echoDelaySec: Double
    ) throws -> (outgoing: URL, incoming: URL)? {
        let outgoingStem: StemTake = duet ? .vocal : .instrumental
        let bedLoop = duet ? 0 : loopSec
        guard let outgoing = try renderCached(
            url: outgoingURL, cue: cueA, duration: duration, stem: outgoingStem, landAt: 0, fadeSec: fadeSec,
            loopSec: bedLoop, echoDelaySec: duet ? 0 : echoDelaySec
        ) else { return nil }
        do {
            guard let incoming = try renderCached(
                url: incomingURL,
                cue: cueB,
                duration: duration,
                stem: duet ? .vocal : .vocalWithBacking,
                landAt: landAt,
                fadeSec: fadeSec,
                loopSec: 0,
                echoDelaySec: duet ? 0 : echoDelaySec
            ) else {
                MidSideStemBaker.removeTempFiles([outgoing])
                return nil
            }
            return (outgoing, incoming)
        } catch {
            MidSideStemBaker.removeTempFiles([outgoing])
            throw error
        }
    }

    func bakePair(
        duet: Bool,
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        duration: Double,
        landAt: Double,
        fadeSec: Double,
        loopSec: Double,
        echoDelaySec: Double,
        onDiagnostic: @escaping @Sendable (String) -> Void
    ) async throws -> (outgoing: URL, incoming: URL)? {
        // A supplies instrumental; B supplies vocal plus some of its backing,
        // then opens into the dry file at LAND. Duet keeps both vocal isolates.
        let outgoingStem: StemTake = duet ? .vocal : .instrumental
        let bedLoop = duet ? 0 : loopSec
        let wash = duet ? 0 : echoDelaySec
        let outgoing = try await renderCAF(
            url: outgoingURL,
            cue: cueA,
            duration: duration,
            stem: outgoingStem,
            landAt: 0,
            fadeSec: fadeSec,
            loopSec: bedLoop,
            echoDelaySec: wash,
            role: "outgoing", onDiagnostic: onDiagnostic
        )
        do {
            let incoming = try await renderCAF(
                url: incomingURL,
                cue: cueB,
                duration: duration,
                stem: duet ? .vocal : .vocalWithBacking,
                landAt: landAt,
                fadeSec: fadeSec,
                loopSec: 0,
                echoDelaySec: wash,
                role: "incoming", onDiagnostic: onDiagnostic
            )
            return (outgoing, incoming)
        } catch {
            MidSideStemBaker.removeTempFiles([outgoing])
            throw error
        }
    }

    private func renderCAF(
        url: URL,
        cue: Double,
        duration: Double,
        stem: StemTake,
        landAt: Double,
        fadeSec: Double,
        loopSec: Double,
        echoDelaySec: Double,
        role: String,
        onDiagnostic: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let cached = try await window(url: url, startSec: max(0, cue), seconds: duration,
                                      role: role, onDiagnostic: onDiagnostic)
        return try mixSlice(
            cached, cue: cue, duration: duration, stem: stem, landAt: landAt, fadeSec: fadeSec,
            loopSec: loopSec, echoDelaySec: echoDelaySec
        )
    }

    private func renderCached(
        url: URL,
        cue: Double,
        duration: Double,
        stem: StemTake,
        landAt: Double,
        fadeSec: Double,
        loopSec: Double,
        echoDelaySec: Double
    ) throws -> URL? {
        guard let revision = CachedWindow.revision(of: url) else { return nil }
        guard let cached = windows.last(where: {
            $0.fileRevision == revision && $0.covers(startSec: max(0, cue), durationSec: duration)
        }) else { return nil }
        return try mixSlice(
            cached, cue: cue, duration: duration, stem: stem, landAt: landAt, fadeSec: fadeSec,
            loopSec: loopSec, echoDelaySec: echoDelaySec
        )
    }

    private func mixSlice(
        _ cached: CachedWindow,
        cue: Double,
        duration: Double,
        stem: StemTake,
        landAt: Double,
        fadeSec: Double,
        loopSec: Double,
        echoDelaySec: Double
    ) throws -> URL {
        guard let slice = cached.slice(startSec: max(0, cue), durationSec: duration) else {
            throw HTDemucsModelError("окно перехода вне кэша")
        }
        let stemL: [Float]
        let stemR: [Float]
        switch stem {
        case .vocal, .vocalWithBacking:
            stemL = slice.vocalsL
            stemR = slice.vocalsR
        case .instrumental:
            stemL = slice.instL
            stemR = slice.instR
        case .dry:
            stemL = slice.dryL
            stemR = slice.dryR
        }
        // Only incoming stems bloom. Outgoing stays instrumental until its fader
        // lets it go, keeping the previous vocal out of the transition.
        let until: Int? = stem == .dry || landAt <= 0.05 ? nil : Int(landAt * cached.rate)
        let amount: Float = stem == .dry ? 0
            : (stem == .vocalWithBacking ? HTDemucsWindowMixer.automixIncomingVocalAmount : 1)
        let mixed = HTDemucsWindowMixer.render(
            dryL: slice.dryL,
            dryR: slice.dryR,
            stemL: stemL,
            stemR: stemR,
            amount: amount,
            untilFrame: until,
            fadeFrames: max(1, Int(max(0.4, fadeSec) * cached.rate))
        )
        var left = mixed.left
        var right = mixed.right
        // Tile phrase loops even when Automix keeps echo dry (echoDelaySec=0).
        if stem == .instrumental, loopSec > 0.25 || echoDelaySec > 0.05 {
            StemMashupGlue.shapeInstrumentalBed(
                left: &left,
                right: &right,
                rate: cached.rate,
                loopSec: loopSec,
                delaySec: echoDelaySec,
                untilFrame: until
            )
        } else if (stem == .vocal || stem == .vocalWithBacking), echoDelaySec > 0.05, let until {
            StemMashupGlue.shapeIncomingVocal(
                left: &left, right: &right, rate: cached.rate, delaySec: echoDelaySec, untilFrame: until
            )
        }
        return try Self.writeCAF(left: left, right: right, rate: cached.rate)
    }

    private func window(url: URL, startSec: Double, seconds: Double, role: String,
                        onDiagnostic: @escaping @Sendable (String) -> Void) async throws -> CachedWindow {
        let revision = CachedWindow.revision(of: url)
        if let revision, let hit = windows.last(where: { $0.fileRevision == revision && $0.covers(startSec: startSec, durationSec: seconds) }) {
            onDiagnostic("cache.hit role=\(role)")
            return hit
        }
        onDiagnostic("cache.miss role=\(role) identity=\(revision == nil ? "unavailable" : "available")")
        let read = try HTDemucsPCM.readWindow(url: url, startSec: startSec, seconds: seconds)
        let started = Date()
        let separated = try await separate(left: read.left, right: read.right)
        onDiagnostic(String(format: "separate.ready role=%@ elapsed=%.1fs", role, Date().timeIntervalSince(started)))
        try Task.checkCancellation()
        if let revision, revision != CachedWindow.revision(of: url) {
            throw HTDemucsModelError("аудиофайл изменился")
        }
        let cached = CachedWindow(
            filePath: url.path,
            fileRevision: revision,
            startSec: read.startSec,
            rate: 44_100,
            reachesFileEnd: read.reachesFileEnd,
            dryL: read.left,
            dryR: read.right,
            vocalsL: separated.vocalsL,
            vocalsR: separated.vocalsR,
            instL: separated.instL,
            instR: separated.instR
        )
        if revision != nil {
            windows.append(cached)
            if windows.count > 4 { windows.removeFirst(windows.count - 4) }
        }
        return cached
    }

    private func separate(left: [Float], right: [Float]) async throws -> (vocalsL: [Float], vocalsR: [Float], instL: [Float], instR: [Float]) {
        let separator = try await model()
        let pipeline = SeparationPipeline(
            source: MemoryPCMSource(left: left, right: right),
            separator: separator
        )
        var vocalsL: [Float] = []
        var vocalsR: [Float] = []
        var instL: [Float] = []
        var instR: [Float] = []
        vocalsL.reserveCapacity(left.count)
        vocalsR.reserveCapacity(left.count)
        instL.reserveCapacity(left.count)
        instR.reserveCapacity(left.count)
        while let block = try await pipeline.nextBlock() {
            try Task.checkCancellation()
            guard let vocals = block.stems[.vocals],
                  let drums = block.stems[.drums],
                  let bass = block.stems[.bass],
                  let other = block.stems[.other] else {
                throw PipelineError.unsupportedModel
            }
            let n = min(block.frameCount, vocals.left.count, drums.left.count, bass.left.count, other.left.count)
            for i in 0..<n {
                vocalsL.append(vocals.left[i])
                vocalsR.append(vocals.right[i])
                instL.append(drums.left[i] + bass.left[i] + other.left[i])
                instR.append(drums.right[i] + bass.right[i] + other.right[i])
            }
        }
        return (vocalsL, vocalsR, instL, instR)
    }

    private func model() async throws -> CoreMLStemSeparator {
        if let separator { return separator }
        if loadWasRefused() { throw HTDemucsModelError("модель не открылась") }
        guard let url = HTDemucsModelStore.shared.installedPackageURL() else {
            throw PipelineError.modelNotFound
        }
        let pending: (id: UUID, task: Task<CoreMLStemSeparator, Error>)
        if let modelLoad {
            pending = modelLoad
        } else {
            pending = (UUID(), Task.detached(priority: .userInitiated) {
                try CoreMLStemSeparator(modelURL: url)
            })
            modelLoad = pending
        }
        do {
            let loaded = try await pending.task.value
            if modelLoad?.id == pending.id { modelLoad = nil }
            separator = loaded
            retryModelLoadAfter = nil
            return loaded
        } catch {
            if modelLoad?.id == pending.id {
                modelLoad = nil
                if !(error is CancellationError) {
                    retryModelLoadAfter = Date().addingTimeInterval(30)
                }
            }
            throw error
        }
    }

    private func outroStart(_ url: URL, seconds: Double) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        let duration = Double(file.length) / rate
        return max(0, duration - seconds)
    }

    private static func writeCAF(left: [Float], right: [Float], rate: Double) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: false
        ) else { throw PipelineError.converterFailed }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-htdemucs-\(UUID().uuidString).caf")
        let output: AVAudioFile
        do {
            output = try MidSideStemBaker.openLinearPCMCAFWriter(at: outURL, format: format)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        let chunk: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let dstL = buffer.floatChannelData?[0],
              let dstR = buffer.floatChannelData?[1] else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }
        var offset = 0
        let n = min(left.count, right.count)
        do {
            while offset < n {
                let count = min(Int(chunk), n - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                left.withUnsafeBufferPointer { src in
                    dstL.update(from: src.baseAddress!.advanced(by: offset), count: count)
                }
                right.withUnsafeBufferPointer { src in
                    dstR.update(from: src.baseAddress!.advanced(by: offset), count: count)
                }
                try output.write(from: buffer)
                offset += count
            }
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        return outURL
    }
}

private enum StemTake {
    case vocal
    case vocalWithBacking
    case instrumental
    case dry
}

private struct CachedWindow: Sendable {
    var filePath: String
    var fileRevision: String?
    var startSec: Double
    var rate: Double
    var reachesFileEnd: Bool
    var dryL: [Float]
    var dryR: [Float]
    var vocalsL: [Float]
    var vocalsR: [Float]
    var instL: [Float]
    var instR: [Float]

    var endSec: Double { startSec + Double(dryL.count) / rate }

    /// Identify audio by its bytes, not by cache path or mutable access time.
    /// Separate playback and analysis caches may contain the identical file,
    /// and both update modification dates when accessed. Reject a file that
    /// changed during hashing; neither paths nor hashes enter session logs.
    static func revision(of url: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let manager = FileManager.default
        guard let before = try? manager.attributesOfItem(atPath: path),
              let size = (before[.size] as? NSNumber)?.int64Value,
              size > 0, size <= 128 * 1_024 * 1_024,
              let changed = before[.modificationDate] as? Date,
              let inode = before[.systemFileNumber] as? NSNumber,
              let device = before[.systemNumber] as? NSNumber,
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? file.close() }
        var digest = SHA256()
        do {
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                digest.update(data: chunk)
            }
        } catch { return nil }
        guard let after = try? manager.attributesOfItem(atPath: path),
              (after[.size] as? NSNumber)?.int64Value == size,
              (after[.modificationDate] as? Date) == changed,
              (after[.systemFileNumber] as? NSNumber) == inode,
              (after[.systemNumber] as? NSNumber) == device else { return nil }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func covers(startSec: Double, durationSec: Double) -> Bool {
        // A cache hit must use the same start boundary as slice(). Otherwise a
        // request up to 50 ms before the window appears covered but fails to
        // slice, forcing the caller onto a non-neural fallback.
        guard startSec.isFinite, durationSec.isFinite, rate.isFinite, rate > 0,
              durationSec > 1 else { return false }
        let offset = ((startSec - self.startSec) * rate).rounded()
        guard offset >= -2, offset < Double(dryL.count) else { return false }
        let from = max(0, Int(offset))
        let available = min(dryL.count, dryR.count, vocalsL.count, vocalsR.count, instL.count, instR.count) - from
        guard available > Int(rate) else { return false }
        let requested = (durationSec * rate).rounded()
        return requested <= Double(available + 2) || reachesFileEnd
    }

    func slice(startSec: Double, durationSec: Double) -> CachedWindow? {
        let i0 = Int(((startSec - self.startSec) * rate).rounded())
        guard i0 >= -2 else { return nil }
        let from = max(0, i0)
        var count = Int((durationSec * rate).rounded())
        if from >= dryL.count { return nil }
        count = min(
            count,
            dryL.count - from,
            dryR.count - from,
            vocalsL.count - from,
            vocalsR.count - from,
            instL.count - from,
            instR.count - from
        )
        guard count > Int(rate) else { return nil }
        return CachedWindow(
            filePath: filePath,
            fileRevision: fileRevision,
            startSec: self.startSec + Double(from) / rate,
            rate: rate,
            reachesFileEnd: reachesFileEnd && from + count >= dryL.count - 8,
            dryL: Array(dryL[from..<(from + count)]),
            dryR: Array(dryR[from..<(from + count)]),
            vocalsL: Array(vocalsL[from..<(from + count)]),
            vocalsR: Array(vocalsR[from..<(from + count)]),
            instL: Array(instL[from..<(from + count)]),
            instR: Array(instR[from..<(from + count)])
        )
    }
}

enum HTDemucsPCM {
    static func readWindow(url: URL, startSec: Double, seconds: Double) throws -> (left: [Float], right: [Float], startSec: Double, reachesFileEnd: Bool) {
        let opened = try MidSideStemBaker.openFloat32Source(url)
        defer { opened.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let file = opened.file
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, file.length > 0 else { throw PipelineError.converterFailed }
        let startFrame = min(file.length - 1, AVAudioFramePosition(max(0, startSec) * rate))
        let want = min(file.length - startFrame, AVAudioFramePosition(max(1, seconds) * rate))
        let frames = AVAudioFrameCount(max(1, want))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw PipelineError.converterFailed
        }
        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frames)
        let n = Int(buffer.frameLength)
        guard n > 0 else { throw PipelineError.converterFailed }
        let left = Array(UnsafeBufferPointer(start: channels[0], count: n))
        let right = file.processingFormat.channelCount > 1
            ? Array(UnsafeBufferPointer(start: channels[1], count: n))
            : left
        let resampled = resampleTo44100(left: left, right: right, sourceRate: rate)
        let start = Double(startFrame) / rate
        let reachesEnd = startFrame + AVAudioFramePosition(n) >= file.length - 8
        return (resampled.left, resampled.right, start, reachesEnd)
    }

    private static func resampleTo44100(left: [Float], right: [Float], sourceRate: Double) -> (left: [Float], right: [Float]) {
        if abs(sourceRate - 44_100) < 1 { return (left, right) }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 2, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(left.count)),
              let src = inBuffer.floatChannelData else {
            return linear44100(left: left, right: right, sourceRate: sourceRate)
        }
        inBuffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { ptr in src[0].update(from: ptr.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { ptr in src[1].update(from: ptr.baseAddress!, count: right.count) }
        let outCount = AVAudioFrameCount(Double(left.count) * 44_100 / sourceRate) + 64
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCount) else {
            return linear44100(left: left, right: right, sourceRate: sourceRate)
        }
        let cursor = OneShotBuffer(buffer: inBuffer)
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, statusPtr in
            cursor.next(statusPtr)
        }
        let n = Int(outBuffer.frameLength)
        guard status != .error, error == nil, n > 0, let dst = outBuffer.floatChannelData else {
            return linear44100(left: left, right: right, sourceRate: sourceRate)
        }
        return (
            Array(UnsafeBufferPointer(start: dst[0], count: n)),
            Array(UnsafeBufferPointer(start: dst[1], count: n))
        )
    }

    private static func linear44100(left: [Float], right: [Float], sourceRate: Double) -> (left: [Float], right: [Float]) {
        let ratio = 44_100 / sourceRate
        let n = max(1, Int(Double(left.count) * ratio))
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        let last = max(0, left.count - 1)
        for i in 0..<n {
            let pos = Double(i) / ratio
            let i0 = min(last, Int(pos))
            let i1 = min(last, i0 + 1)
            let t = Float(pos - Double(i0))
            outL[i] = left[i0] * (1 - t) + left[i1] * t
            outR[i] = right[i0] * (1 - t) + right[i1] * t
        }
        return (outL, outR)
    }
}

private final class OneShotBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private var used = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if used {
            status.pointee = .endOfStream
            return nil
        }
        used = true
        status.pointee = .haveData
        return buffer
    }
}
