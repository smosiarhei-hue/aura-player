import AVFAudio
import Foundation

/// Separates the outro and intro while the song plays, then hands the mashup
/// decks a vocal CAF and an instrumental CAF. Without the model on disk this
/// returns nil and the caller keeps the mid/side bake.
public enum HTDemucsMashupBake {
    public nonisolated(unsafe) static var lastBackend = "hybrid"
    public static let prewarmSeconds: Double = 36

    public static func prewarm(
        outgoingFile: URL,
        incomingFile: URL,
        onStatus: @escaping @Sendable (String) -> Void
    ) async {
        if await HTDemucsRuntime.shared.loadWasRefused() { return }
        do {
            onStatus("HTDemucs · модель 0%")
            _ = try await HTDemucsModelStore.shared.prepare { fraction in
                onStatus("HTDemucs · модель \(Int(fraction * 100))%")
            }
            onStatus("HTDemucs · компилирую")
            try await HTDemucsRuntime.shared.prewarm(
                outgoingFile: outgoingFile,
                incomingFile: incomingFile,
                seconds: prewarmSeconds,
                onStatus: onStatus
            )
            onStatus("HTDemucs · готово")
        } catch is CancellationError {
            return
        } catch {
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
        echoDelaySec: Double = 0
    ) async throws -> (outgoing: URL, incoming: URL)? {
        guard HTDemucsModelStore.shared.installedPackageURL() != nil else { return nil }
        let musical = min(MidSideStemBaker.maximumDurationSec, max(4, blendSec))
        let duration = min(MidSideStemBaker.maximumDurationSec, musical + max(0, padSec))
        let rate = min(1.04, max(0.96, playbackRate))
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
            echoDelaySec: echoDelaySec
        )
        if pair != nil { lastBackend = "htdemucs" }
        return pair
    }
}

public actor HTDemucsRuntime {
    public static let shared = HTDemucsRuntime()

    private var separator: CoreMLStemSeparator?
    private var windows: [CachedWindow] = []
    private var jobs = 0
    /// Core ML refused this package. Further songs stay on the mid/side bake.
    private var refusedLoad = false

    func loadWasRefused() -> Bool { refusedLoad }

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
        echoDelaySec: Double
    ) async throws -> (outgoing: URL, incoming: URL)? {
        if jobs > 0 {
            return try cachedPair(
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
            echoDelaySec: echoDelaySec
        )
    }

    func prewarm(
        outgoingFile: URL,
        incomingFile: URL,
        seconds: Double,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        jobs += 1
        defer { jobs -= 1 }
        _ = try await model()
        onStatus("HTDemucs · аутро")
        _ = try await window(url: outgoingFile, startSec: outroStart(outgoingFile, seconds: seconds), seconds: seconds)
        try Task.checkCancellation()
        onStatus("HTDemucs · интро")
        _ = try await window(url: incomingFile, startSec: 0, seconds: seconds)
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
                stem: .vocal,
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
        echoDelaySec: Double
    ) async throws -> (outgoing: URL, incoming: URL)? {
        // Ending song is the instrumental bed. The next song enters as vocal,
        // then opens into the dry file at LAND. Duet is both vocals.
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
            echoDelaySec: wash
        )
        do {
            let incoming = try await renderCAF(
                url: incomingURL,
                cue: cueB,
                duration: duration,
                stem: .vocal,
                landAt: landAt,
                fadeSec: fadeSec,
                loopSec: 0,
                echoDelaySec: wash
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
        echoDelaySec: Double
    ) async throws -> URL {
        let cached = try await window(url: url, startSec: max(0, cue), seconds: duration)
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
        guard let cached = windows.last(where: {
            $0.filePath == url.path && $0.covers(startSec: max(0, cue), durationSec: duration)
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
        case .vocal:
            stemL = slice.vocalsL
            stemR = slice.vocalsR
        case .instrumental:
            stemL = slice.instL
            stemR = slice.instR
        case .dry:
            stemL = slice.dryL
            stemR = slice.dryR
        }
        // Bloom only the incoming vocal. The outgoing bed stays instrumental
        // until the live fader lets it go; blooming it would bring its vocal back.
        let until: Int? = stem == .dry || landAt <= 0.05 ? nil : Int(landAt * cached.rate)
        let mixed = HTDemucsWindowMixer.render(
            dryL: slice.dryL,
            dryR: slice.dryR,
            stemL: stemL,
            stemR: stemR,
            amount: stem == .dry ? 0 : 1,
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
        } else if stem == .vocal, echoDelaySec > 0.05, let until {
            StemMashupGlue.shapeIncomingVocal(
                left: &left, right: &right, rate: cached.rate, delaySec: echoDelaySec, untilFrame: until
            )
        }
        return try Self.writeCAF(left: left, right: right, rate: cached.rate)
    }

    private func window(url: URL, startSec: Double, seconds: Double) async throws -> CachedWindow {
        if let hit = windows.last(where: { $0.filePath == url.path && $0.covers(startSec: startSec, durationSec: seconds) }) {
            return hit
        }
        let read = try HTDemucsPCM.readWindow(url: url, startSec: startSec, seconds: seconds)
        let separated = try await separate(left: read.left, right: read.right)
        let cached = CachedWindow(
            filePath: url.path,
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
        windows.append(cached)
        if windows.count > 4 { windows.removeFirst(windows.count - 4) }
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
        if refusedLoad { throw HTDemucsModelError("модель не открылась") }
        guard let url = HTDemucsModelStore.shared.installedPackageURL() else {
            throw PipelineError.modelNotFound
        }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try CoreMLStemSeparator(modelURL: url)
            }.value
            separator = loaded
            return loaded
        } catch {
            let text = (error as? HTDemucsModelError)?.description ?? ""
            if !text.contains("мало места") { refusedLoad = true }
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
    case instrumental
    case dry
}

private struct CachedWindow: Sendable {
    var filePath: String
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

    func covers(startSec: Double, durationSec: Double) -> Bool {
        guard startSec >= self.startSec - 0.05 else { return false }
        if startSec + durationSec <= endSec + 0.2 { return true }
        return reachesFileEnd && startSec <= endSec
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
