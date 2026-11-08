// Path: Packages/AutoMixV2/Sources/AudioEngineCore/MidSideStemBaker.swift
//
// Lab-style Mid/Side mashup bake — memory-light:
// only the transition window is read, processed in small chunks, and written
// to a temp CAF on disk. Peak RAM ≈ a few chunks (~256 KB), not full tracks.
//
// Primary path: bakeTransitionMaster — one stereo master of A+B (instr + volumes).

@preconcurrency import AVFAudio
import AVFoundation
import Foundation

public enum MidSideStemMode: Sendable, Equatable {
    case instrumental
    case vocal
    case dry
}

public struct MidSideBakeRequest: Sendable, Equatable {
    public var fileURL: URL
    public var cueSec: Double
    public var durationSec: Double
    public var mode: MidSideStemMode
    /// 0…1 stem strength.
    public var amount: Float
    /// When > 0: crossfade this stem into the dry mix after this many seconds.
    public var instrumentalUntilSec: Double
    /// Length of the stem→dry bloom. One bar for the lab AutoMix LAND.
    public var bloomFadeSec: Double
    /// Phrase length for the instrumental bed. 0 leaves the outro unlooped.
    public var loopSec: Double
    /// Tempo echo. 0 skips the wash that glues the vocal into the bed.
    public var echoDelaySec: Double

    public init(
        fileURL: URL,
        cueSec: Double,
        durationSec: Double,
        mode: MidSideStemMode,
        amount: Float = 1,
        instrumentalUntilSec: Double = 0,
        bloomFadeSec: Double = 0.08,
        loopSec: Double = 0,
        echoDelaySec: Double = 0
    ) {
        self.fileURL = fileURL
        self.cueSec = cueSec
        self.durationSec = durationSec
        self.mode = mode
        self.amount = amount
        self.instrumentalUntilSec = instrumentalUntilSec
        self.bloomFadeSec = bloomFadeSec
        self.loopSec = loopSec
        self.echoDelaySec = echoDelaySec
    }
}

/// Recipe for a single mastered mashup window (A+B summed offline).
public struct MidSideMasterBakeRequest: Sendable, Equatable {
    public var outgoingURL: URL
    public var incomingURL: URL
    public var cueA: Double
    public var cueB: Double
    public var durationSec: Double
    /// Progress (0…1) where B lead returns (LAND handoff).
    public var handoffProgress: Double
    public var outgoingVolumeHold: Double
    public var incomingVolumeLag: Double
    public var isBeatmatched: Bool
    /// Stem carve for outgoing (A). Duet uses `.vocal`.
    public var outgoingMode: MidSideStemMode
    /// Stem carve for incoming (B). Duet uses `.dry` (full mix).
    public var incomingMode: MidSideStemMode
    /// Lab Duet volume curve (invite → stack → LAND).
    public var useDuetVolumes: Bool

    public init(
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        durationSec: Double,
        handoffProgress: Double,
        outgoingVolumeHold: Double = 0.42,
        incomingVolumeLag: Double = 0.18,
        isBeatmatched: Bool = true,
        outgoingMode: MidSideStemMode = .instrumental,
        incomingMode: MidSideStemMode = .instrumental,
        useDuetVolumes: Bool = false
    ) {
        self.outgoingURL = outgoingURL
        self.incomingURL = incomingURL
        self.cueA = cueA
        self.cueB = cueB
        self.durationSec = durationSec
        self.handoffProgress = handoffProgress
        self.outgoingVolumeHold = outgoingVolumeHold
        self.incomingVolumeLag = incomingVolumeLag
        self.isBeatmatched = isBeatmatched
        self.outgoingMode = outgoingMode
        self.incomingMode = incomingMode
        self.useDuetVolumes = useDuetVolumes
    }
}

public enum MidSideStemBaker {
    /// Soft cap so a bad cue can't allocate a huge bake (Lab blend ≤ ~36s).
    public static let maximumDurationSec: Double = 40
    private static let chunkFrames: AVAudioFrameCount = 4_096

    // MARK: - Transition master (A+B → one CAF)

    /// Bake ONE VOCAL mashup as a single stereo master: A instrumental + B instr→dry,
    /// mashed with Lab-style dual-deck volumes. Caller must delete the URL when done.
    public static func bakeTransitionMaster(_ request: MidSideMasterBakeRequest) throws -> URL {
        let duration = min(maximumDurationSec, max(4, request.durationSec))
        let cueA = max(0, request.cueA)
        let cueB = max(0, request.cueB)
        let handoff = min(0.85, max(0.35, request.handoffProgress))
        let untilSec = duration * handoff

        let fileA = try AVAudioFile(forReading: request.outgoingURL)
        let fileB = try AVAudioFile(forReading: request.incomingURL)
        let formatA = fileA.processingFormat
        let formatB = fileB.processingFormat
        let rate = formatA.sampleRate
        guard rate.isFinite, rate > 0, fileA.length > 0, fileB.length > 0,
              abs(formatA.sampleRate - formatB.sampleRate) < 1.0 else {
            // Divergent sample rates → caller falls back to live EQ path.
            throw AudioEngineCoreError.unsupportedOutputFormat
        }

        let startA = min(fileA.length - 1, AVAudioFramePosition(cueA * rate))
        let startB = min(fileB.length - 1, AVAudioFramePosition(cueB * formatB.sampleRate))
        let maxA = fileA.length - startA
        let maxB = fileB.length - startB
        let availableSec = min(Double(maxA), Double(maxB)) / rate
        let wantSec = min(duration + 0.5, availableSec)
        let totalFrames = AVAudioFrameCount(
            max(1, min(min(maxA, maxB), AVAudioFramePosition(wantSec * rate)))
        )
        let untilFrame = AVAudioFrameCount(min(Double(totalFrames), untilSec * rate))
        // Apple Automix LAND is a hard stem cut — short bloom only to avoid a click.
        let fadeFrames = AVAudioFrameCount(max(1, Int(0.08 * rate)))

        // Master is always stereo float at A's processing format.
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-mashup-master-\(UUID().uuidString).caf")
        // Never pass compressed-source `.settings` into forWriting — streamed mp3/aac
        // caches throw Foundation._GenericObjCError 0 and kill the mashup bake.
        let output = try openLinearPCMCAFWriter(at: outURL, format: outFormat)

        // Peak RAM: 3 PCM chunks — never both full windows.
        guard let bufA = AVAudioPCMBuffer(pcmFormat: formatA, frameCapacity: chunkFrames),
              let bufB = AVAudioPCMBuffer(pcmFormat: formatB, frameCapacity: chunkFrames),
              let bufOut = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }

        fileA.framePosition = startA
        fileB.framePosition = startB

        var written: AVAudioFrameCount = 0
        // Lab multiband mid: ~150 Hz sub · ~800 Hz body · ~2.8 kHz presence.
        var aLp: Float = 0, aBody: Float = 0, aPres: Float = 0
        var bLp: Float = 0, bBody: Float = 0, bPres: Float = 0
        let lpAlpha = Float(1 - exp(-2 * Double.pi * 150 / rate))
        let bodyAlpha = Float(1 - exp(-2 * Double.pi * 800 / rate))
        let presAlpha = Float(1 - exp(-2 * Double.pi * 2800 / rate))
        let chA = Int(formatA.channelCount)
        let chB = Int(formatB.channelCount)
        let hold = request.outgoingVolumeHold
        let lag = request.incomingVolumeLag
        let beatmatched = request.isBeatmatched

        while written < totalFrames {
            let got: AVAudioFrameCount = try autoreleasepool {
                let n = min(chunkFrames, totalFrames - written)
                bufA.frameLength = 0
                bufB.frameLength = 0
                try fileA.read(into: bufA, frameCount: n)
                try fileB.read(into: bufB, frameCount: n)
                let got = min(bufA.frameLength, bufB.frameLength)
                guard got > 0 else { return 0 }
                bufOut.frameLength = got

                processChunk(
                    input: bufA,
                    output: bufA,
                    frames: got,
                    channels: chA,
                    mode: request.outgoingMode,
                    amount: request.outgoingMode == .dry ? 0 : 1,
                    absoluteFrame: written,
                    untilFrame: 0,
                    fadeFrames: fadeFrames,
                    midLp: &aLp,
                    midBody: &aBody,
                    midPres: &aPres,
                    lpAlpha: lpAlpha,
                    bodyAlpha: bodyAlpha,
                    presAlpha: presAlpha
                )
                processChunk(
                    input: bufB,
                    output: bufB,
                    frames: got,
                    channels: chB,
                    mode: request.incomingMode,
                    amount: request.incomingMode == .dry ? 0 : 1,
                    absoluteFrame: written,
                    untilFrame: request.incomingMode == .instrumental ? untilFrame : 0,
                    fadeFrames: fadeFrames,
                    midLp: &bLp,
                    midBody: &bBody,
                    midPres: &bPres,
                    lpAlpha: lpAlpha,
                    bodyAlpha: bodyAlpha,
                    presAlpha: presAlpha
                )

                mixMasterChunk(
                    outgoing: bufA,
                    incoming: bufB,
                    output: bufOut,
                    frames: got,
                    channelsA: chA,
                    channelsB: chB,
                    absoluteFrame: written,
                    totalFrames: totalFrames,
                    handoff: handoff,
                    hold: hold,
                    lag: lag,
                    beatmatched: beatmatched,
                    useDuetVolumes: request.useDuetVolumes
                )

                try output.write(from: bufOut)
                return got
            }
            guard got > 0 else { break }
            written += got
            if fileA.framePosition >= fileA.length || fileB.framePosition >= fileB.length {
                break
            }
        }

        return outURL
    }

    /// Apple Automix master: A vocal over B instrumental → B dry at LAND.
    public static func bakeOneVocalMaster(
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        blendSec: Double,
        handoffProgress: Double,
        outgoingVolumeHold: Double,
        incomingVolumeLag: Double,
        isBeatmatched: Bool
    ) throws -> URL {
        try bakeTransitionMaster(
            MidSideMasterBakeRequest(
                outgoingURL: outgoingURL,
                incomingURL: incomingURL,
                cueA: cueA,
                cueB: cueB,
                durationSec: blendSec,
                handoffProgress: handoffProgress,
                outgoingVolumeHold: outgoingVolumeHold,
                incomingVolumeLag: incomingVolumeLag,
                isBeatmatched: isBeatmatched,
                outgoingMode: .vocal,
                incomingMode: .instrumental,
                useDuetVolumes: false
            )
        )
    }

    /// Lab Modern Duet: A vocal isolate + B full mix → one stereo master.
    public static func bakeDuetMaster(
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        blendSec: Double,
        handoffProgress: Double,
        outgoingVolumeHold: Double,
        incomingVolumeLag: Double,
        isBeatmatched: Bool
    ) throws -> URL {
        try bakeTransitionMaster(
            MidSideMasterBakeRequest(
                outgoingURL: outgoingURL,
                incomingURL: incomingURL,
                cueA: cueA,
                cueB: cueB,
                durationSec: blendSec,
                handoffProgress: handoffProgress,
                outgoingVolumeHold: outgoingVolumeHold,
                incomingVolumeLag: incomingVolumeLag,
                isBeatmatched: isBeatmatched,
                outgoingMode: .vocal,
                incomingMode: .dry,
                useDuetVolumes: true
            )
        )
    }

    /// Lab-faithful dual-deck stems: A vocal isolate + B dry. Rates stay on the decks.
    public static func bakeDuetStemPair(
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        blendSec: Double,
        padSec: Double = 0
    ) throws -> (outgoing: URL, incoming: URL) {
        let musical = min(maximumDurationSec, max(4, blendSec))
        let duration = min(maximumDurationSec, musical + max(0, padSec))
        let aURL = try bakeToTempFile(
            MidSideBakeRequest(
                fileURL: outgoingURL,
                cueSec: cueA,
                durationSec: duration,
                mode: .vocal,
                amount: 0.92
            )
        )
        do {
            let bURL = try bakeToTempFile(
                MidSideBakeRequest(
                    fileURL: incomingURL,
                    cueSec: cueB,
                    durationSec: duration,
                    mode: .dry,
                    amount: 0
                )
            )
            return (aURL, bURL)
        } catch {
            removeTempFiles([aURL])
            throw error
        }
    }

    /// Lab stem AutoMix: ending song stays instrumental, the next song enters
    /// as vocal and opens into the dry file across one bar at LAND.
    /// `padSec` extends the CAF past the musical blend so bake-lag never
    /// drains the stem before dry B is scheduled.
    public static func bakeAutomixStemPair(
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        blendSec: Double,
        handoffProgress: Double,
        padSec: Double = 0,
        landFadeSec: Double = 0,
        playbackRate: Double = 1,
        loopSec: Double = 0,
        echoDelaySec: Double = 0
    ) throws -> (outgoing: URL, incoming: URL) {
        let musical = min(maximumDurationSec, max(4, blendSec))
        let duration = min(maximumDurationSec, musical + max(0, padSec))
        let rate = min(1.04, max(0.96, playbackRate))
        let handoff = min(0.92, max(0.35, handoffProgress))
        let fadeWall = landFadeSec > 0.25 ? landFadeSec : max(0.9, min(2.4, musical * 0.12))
        var landWall = musical * handoff
        if landWall > duration - 0.3 { landWall = max(fadeWall + 0.35, duration - 0.3) }
        let landAtSec = landWall * rate
        let aURL = try bakeToTempFile(
            MidSideBakeRequest(
                fileURL: outgoingURL,
                cueSec: cueA,
                durationSec: duration,
                mode: .instrumental,
                amount: 0.78,
                loopSec: loopSec,
                echoDelaySec: echoDelaySec
            )
        )
        do {
            let bURL = try bakeToTempFile(
                MidSideBakeRequest(
                    fileURL: incomingURL,
                    cueSec: cueB,
                    durationSec: duration,
                    mode: .vocal,
                    amount: 0.8,
                    instrumentalUntilSec: landAtSec,
                    bloomFadeSec: fadeWall * rate,
                    echoDelaySec: echoDelaySec
                )
            )
            return (aURL, bURL)
        } catch {
            removeTempFiles([aURL])
            throw error
        }
    }

    // MARK: - Single-stem bake (tests / DualDeck helpers)

    /// Backend used by the most recent `bakeToTempFile` / Automix stem pair.
    public static var lastSeparationBackend: StemSeparationBackend {
        StemSeparator.lastBackend
    }

    /// Bake one mashup slice to a temp CAF. Caller must delete the URL when done.
    /// Whole-window separation so AUSoundIsolation / hybrid keep consistent state.
    public static func bakeToTempFile(_ request: MidSideBakeRequest) throws -> URL {
        let duration = min(maximumDurationSec, max(1, request.durationSec))
        let cue = max(0, request.cueSec)
        let amount = min(1, max(0, request.amount))
        let until = min(duration, max(0, request.instrumentalUntilSec))

        // Force float32 non-interleaved on read so m4a/mp3 match the stem DSP
        // and the 4-arg CAF writer (no AVAudioConverter / Swift 6 capture issues).
        // Device logs: converting-open of a file AVPlayer already holds throws
        // com.apple.coreaudio.avfaudio 1685348671 ('dtsg').
        let opened = try openFloat32Source(request.fileURL)
        let source = opened.file
        defer { opened.scratch.map { try? FileManager.default.removeItem(at: $0) } }
        let format = source.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, source.length > 0,
              format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }

        let startFrame = min(source.length - 1, AVAudioFramePosition(cue * rate))
        let maxFrames = source.length - startFrame
        let availableSec = Double(maxFrames) / rate
        let wantSec = min(duration + 1.0, availableSec)
        let wantFrames = AVAudioFramePosition(wantSec * rate)
        let totalFrames = AVAudioFrameCount(min(maxFrames, max(1, wantFrames)))
        let untilFrame = AVAudioFrameCount(min(Double(totalFrames), until * rate))
        let channels = Int(format.channelCount)
        let fadeFrames = AVAudioFrameCount(max(1, Int(max(0.04, request.bloomFadeSec) * rate)))

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-mashup-\(UUID().uuidString).caf")
        let output: AVAudioFile
        do {
            output = try openLinearPCMCAFWriter(at: outURL, format: format)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }

        // Read the whole mashup window once (≤ ~40s ≈ 14 MB stereo float).
        guard let window = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }
        source.framePosition = startFrame
        do {
            try source.read(into: window, frameCount: totalFrames)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        let got = window.frameLength
        guard got > 0, let srcL = window.floatChannelData?[0] else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }
        let srcR = channels > 1 ? (window.floatChannelData?[1] ?? srcL) : srcL
        let n = Int(got)

        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        left.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: srcL, count: n) }
        right.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: srcR, count: n) }

        if request.mode != .dry, amount >= 0.05, channels >= 2 {
            left.withUnsafeMutableBufferPointer { lBuf in
                right.withUnsafeMutableBufferPointer { rBuf in
                    StemSeparator.separateWindow(
                        left: lBuf.baseAddress!,
                        right: rBuf.baseAddress!,
                        frames: n,
                        mode: request.mode,
                        amount: amount,
                        sampleRate: rate
                    )
                }
            }
        } else if request.mode != .dry, amount >= 0.05 {
            // Mono: hybrid-only (AU needs stereo).
            left.withUnsafeMutableBufferPointer { lBuf in
                right.withUnsafeMutableBufferPointer { rBuf in
                    var state = StemSeparator.State()
                    if request.mode == .instrumental {
                        StemSeparator.renderHybridInstrumental(
                            left: lBuf.baseAddress!, right: rBuf.baseAddress!,
                            frames: n, amount: amount, sampleRate: rate, state: &state
                        )
                    } else {
                        StemSeparator.separateWindow(
                            left: lBuf.baseAddress!, right: rBuf.baseAddress!,
                            frames: n, mode: request.mode, amount: amount, sampleRate: rate
                        )
                    }
                }
            }
            StemSeparator.lastBackend = .hybridSpectral
        } else {
            StemSeparator.lastBackend = .hybridSpectral
        }

        // Phrase-loop the instrumental bed on the beat grid before LAND; optional
        // echo wash stays opt-in (PlayerCore Automix usually passes delay=0).
        if request.mode == .instrumental, request.loopSec > 0.25 || request.echoDelaySec > 0.05 {
            StemMashupGlue.shapeInstrumentalBed(
                left: &left,
                right: &right,
                rate: rate,
                loopSec: request.loopSec,
                delaySec: request.echoDelaySec,
                untilFrame: untilFrame > 0 ? Int(untilFrame) : nil
            )
        } else if request.mode == .vocal, request.echoDelaySec > 0.05 {
            StemMashupGlue.shapeIncomingVocal(
                left: &left,
                right: &right,
                rate: rate,
                delaySec: request.echoDelaySec,
                untilFrame: Int(untilFrame)
            )
        }

        // Stem→dry bloom near LAND. The incoming vocal becomes the full song.
        if request.mode != .dry, untilFrame > 0, untilFrame < got {
            let dryL = srcL
            let dryR = srcR
            let fadeStart = untilFrame > fadeFrames ? untilFrame - fadeFrames : 0
            for i in 0..<n {
                let frame = AVAudioFrameCount(i)
                if frame >= untilFrame {
                    left[i] = dryL[i]
                    right[i] = dryR[i]
                } else if frame >= fadeStart {
                    let t = Float(frame - fadeStart) / Float(max(1, fadeFrames))
                    let ease = min(1, max(0, t))
                    let s = ease * ease * (3 - 2 * ease)
                    let wa = 1 - s
                    let wb = s
                    left[i] = left[i] * wa + dryL[i] * wb
                    right[i] = right[i] * wa + dryR[i] * wb
                }
            }
        }

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let oL = outBuf.floatChannelData?[0] else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }
        let oR = channels > 1 ? outBuf.floatChannelData?[1] : nil

        var offset = 0
        do {
            while offset < n {
                let count = min(Int(chunkFrames), n - offset)
                outBuf.frameLength = AVAudioFrameCount(count)
                left.withUnsafeBufferPointer { lPtr in
                    right.withUnsafeBufferPointer { rPtr in
                        oL.update(from: lPtr.baseAddress!.advanced(by: offset), count: count)
                        if let oR {
                            oR.update(from: rPtr.baseAddress!.advanced(by: offset), count: count)
                        }
                    }
                }
                try output.write(from: outBuf)
                offset += count
            }
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }

        return outURL
    }

    public static func removeTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// CAF Linear PCM settings that `AVAudioFile(forWriting:)` accepts for stream caches.
    /// Do not use `AVAudioFormat.settings` from a compressed source — it throws on device.
    public static func linearPCMCAFSettings(for format: AVAudioFormat) -> [String: Any] {
        let isFloat = format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatFloat64
        let bitDepth: Int
        switch format.commonFormat {
        case .pcmFormatInt16: bitDepth = 16
        case .pcmFormatInt32: bitDepth = 32
        case .pcmFormatFloat64: bitDepth = 64
        default: bitDepth = 32
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat || format.commonFormat == .pcmFormatFloat32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved
        ]
    }

    /// Float32 non-interleaved reader. A converting open of a cache AVPlayer or
    /// AVAudioEngine already holds throws `'dta?'` / `'dtsg'` (1685348671).
    /// Order: converting open → private copy → plain open of the copy → decode
    /// that copy into a float32 CAF (AVAudioFile, then AVAssetReader).
    /// Never reopen the live URL as a last resort.
    public static func openFloat32Source(_ url: URL) throws -> (file: AVAudioFile, scratch: URL?) {
        if let file = try? AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ), file.length > 0 {
            return (file, nil)
        }

        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-src-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            // Copy can race a still-writing download; decode the original without AVAudioFile.
            if let caf = try? decodeCompressedToFloat32CAF(url) {
                return (try AVAudioFile(forReading: caf), caf)
            }
            throw error
        }

        if let file = try? AVAudioFile(
            forReading: copy,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ), file.length > 0 {
            return (file, copy)
        }
        if let plain = try? AVAudioFile(forReading: copy),
           plain.length > 0,
           plain.processingFormat.commonFormat == .pcmFormatFloat32,
           !plain.processingFormat.isInterleaved {
            return (plain, copy)
        }

        // Converting open of the copy still failed (common for some m4a/mp3).
        // Decode through AVAudioConverter / AVAssetReader into a private CAF.
        do {
            let caf = try decodeCompressedToFloat32CAF(copy)
            try? FileManager.default.removeItem(at: copy)
            return (try AVAudioFile(forReading: caf), caf)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error
        }
    }

    /// Private copy of a compressed cache for native deck scheduling. Prefer this
    /// over opening the live URL when AutoMix falls back from a failed stem bake.
    /// Always copy m4a/mp3/aac first — a successful live open still leaves the file
    /// locked for the next bake/LAND (`'dta?'` on the same path).
    public static func openPlaybackSource(_ url: URL) throws -> (file: AVAudioFile, scratch: URL?) {
        let ext = url.pathExtension.lowercased()
        let needsPrivateCopy = ["m4a", "mp3", "aac", "m4b", "mp4"].contains(ext)
        // CAF / WAV from our own bake can open live; compressed caches always copy.
        if !needsPrivateCopy, let file = try? AVAudioFile(forReading: url), file.length > 0 {
            return (file, nil)
        }

        let copyExt = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-play-\(UUID().uuidString).\(copyExt)")
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            let caf = try decodeCompressedToFloat32CAF(url)
            return (try AVAudioFile(forReading: caf), caf)
        }
        if let file = try? AVAudioFile(forReading: copy), file.length > 0 {
            return (file, copy)
        }
        // Last path: float32 CAF via AVAudioFile converter, then AVAssetReader.
        let caf = try decodeCompressedToFloat32CAF(copy)
        try? FileManager.default.removeItem(at: copy)
        return (try AVAudioFile(forReading: caf), caf)
    }

    /// Turn a compressed source into a float32 non-interleaved CAF. Used when
    /// `AVAudioFile(..., commonFormat:)` refuses the container with `'dta?'`.
    /// Field 1107: AVAudioFile also fails on a private m4a/mp3 copy — AVAssetReader
    /// does not share that open path and can still materialize PCM for bake/LAND.
    public static func decodeCompressedToFloat32CAF(_ url: URL) throws -> URL {
        if let caf = try? decodeCompressedViaAVAudioFile(url) {
            return caf
        }
        return try decodeCompressedViaAVAssetReader(url)
    }

    /// First decode path: AVAudioFile + AVAudioConverter (works for unlocked CAF/WAV
    /// and some mp3 copies). Throws `'dta?'` on many live Yandex m4a/mp3 caches.
    private static func decodeCompressedViaAVAudioFile(_ url: URL) throws -> URL {
        let source = try AVAudioFile(forReading: url)
        guard source.length > 0 else { throw AudioEngineCoreError.unsupportedOutputFormat }
        let rate = source.processingFormat.sampleRate
        let channels = max(1, min(2, source.processingFormat.channelCount))
        guard rate.isFinite, rate > 0,
              let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: channels,
                interleaved: false
              ) else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-pcm-\(UUID().uuidString).caf")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: outURL) } }
        let output = try openLinearPCMCAFWriter(at: outURL, format: outFormat)
        guard let converter = AVAudioConverter(from: source.processingFormat, to: outFormat),
              let inBuf = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 8_192),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8_192) else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreateConverter
        }
        let cursor = Float32DecodeCursor(file: source, buffer: inBuf)
        while true {
            var convertError: NSError?
            let status = converter.convert(to: outBuf, error: &convertError) { _, statusPtr in
                cursor.next(statusPtr)
            }
            if let convertError {
                try? FileManager.default.removeItem(at: outURL)
                throw AudioEngineCoreError.conversionFailed(convertError.localizedDescription)
            }
            if status == .error {
                try? FileManager.default.removeItem(at: outURL)
                throw AudioEngineCoreError.conversionFailed("PCM decode made no progress")
            }
            if outBuf.frameLength > 0 {
                try output.write(from: outBuf)
            }
            if status == .endOfStream { break }
        }
        completed = true
        return outURL
    }

    /// Second decode path: AVAssetReader → float32 CAF. Bypasses AVAudioFile's
    /// ExtAudioFile open that returns `com.apple.coreaudio.avfaudio` / `'dta?'`.
    private static func decodeCompressedViaAVAssetReader(_ url: URL) throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioEngineCoreError.conversionFailed("AVAsset has no audio track")
        }

        let outRate = 44_100.0
        let channels: AVAudioChannelCount = 2
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outRate,
            channels: channels,
            interleaved: false
        ) else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioEngineCoreError.conversionFailed("AVAssetReader: \(error.localizedDescription)")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: Int(channels),
            AVSampleRateKey: outRate
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(trackOutput) else {
            throw AudioEngineCoreError.conversionFailed("AVAssetReader cannot add audio output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            let detail = reader.error?.localizedDescription ?? "startReading failed"
            throw AudioEngineCoreError.conversionFailed("AVAssetReader: \(detail)")
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-asset-\(UUID().uuidString).caf")
        let output: AVAudioFile
        do {
            output = try openLinearPCMCAFWriter(at: outURL, format: outFormat)
        } catch {
            reader.cancelReading()
            throw error
        }

        // Interleaved float32 from the reader → non-interleaved float32 CAF.
        let capacity: AVAudioFrameCount = 8_192
        let bytesPerFrame = Int(channels) * MemoryLayout<Float>.size
        guard let planarBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity),
              let left = planarBuf.floatChannelData?[0],
              let right = planarBuf.floatChannelData?[1]
        else {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }

        var wroteFrames: AVAudioFramePosition = 0
        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0 else { continue }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, length >= bytesPerFrame else { continue }

            let availableFrames = length / bytesPerFrame
            let frames = min(frameCount, availableFrames)
            guard frames > 0 else { continue }
            let floats = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: frames * Int(channels))

            var offset = 0
            while offset < frames {
                let chunk = min(Int(capacity), frames - offset)
                planarBuf.frameLength = AVAudioFrameCount(chunk)
                for i in 0..<chunk {
                    let base = (offset + i) * Int(channels)
                    left[i] = floats[base]
                    right[i] = floats[base + 1]
                }
                do {
                    try output.write(from: planarBuf)
                } catch {
                    reader.cancelReading()
                    try? FileManager.default.removeItem(at: outURL)
                    throw error
                }
                wroteFrames += AVAudioFramePosition(chunk)
                offset += chunk
            }
        }

        if reader.status == .failed {
            let detail = reader.error?.localizedDescription ?? "AVAssetReader failed"
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.conversionFailed(detail)
        }
        guard wroteFrames > 0 else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.conversionFailed("AVAssetReader produced no PCM frames")
        }
        return outURL
    }

    /// Open a CAF writer whose *processing* format matches `format` (buffers we write).
    /// Settings-only `forWriting` still throws `Foundation._GenericObjCError` 0 on device
    /// for some m4a/mp3-derived formats — the 4-arg initializer is required.
    public static func openLinearPCMCAFWriter(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: linearPCMCAFSettings(for: format),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    // MARK: - DSP

    /// MashupLiveStyle.volumes mirrored (AudioEngineCore cannot import MixPlanner).
    private static func mashupVolumes(
        progress: Double,
        hold rawHold: Double,
        lag rawLag: Double,
        handoff rawHandoff: Double,
        beatmatched: Bool,
        useDuetVolumes: Bool = false
    ) -> (outgoing: Float, incoming: Float) {
        if useDuetVolumes {
            return duetVolumes(
                progress: progress,
                hold: rawHold,
                lag: rawLag,
                handoff: rawHandoff
            )
        }
        // Apple Automix volumes: both stems full during mashup; A hard-cuts at LAND.
        let p = min(1, max(0, progress))
        let handoff = min(0.98, max(0.82, rawHandoff))
        let lag = min(0.08, max(0.0, rawLag))
        let out: Float = p < handoff ? 1 : 0
        let inVol: Float
        if p <= lag, lag > 0.001 {
            inVol = Float(p / lag)
        } else {
            inVol = 1
        }
        return (out, min(1, max(0, inVol)))
    }

    /// Lab `oneBarDuetVolumes` — A vocal stays strong through stack, then LAND.
    private static func duetVolumes(
        progress: Double,
        hold rawHold: Double,
        lag rawLag: Double,
        handoff rawHandoff: Double
    ) -> (outgoing: Float, incoming: Float) {
        let p = min(1, max(0, progress))
        let handoff = min(0.72, max(0.52, rawHandoff))
        let invite = min(0.14, max(0.05, rawLag))
        let aDual = Float(min(0.92, max(0.72, rawHold)))
        let landEnd = 0.94

        let out: Float
        if p <= invite {
            out = 1
        } else if p <= handoff {
            let t = Float((p - invite) / max(0.001, handoff - invite))
            out = 1 - t * (1 - aDual)
        } else if p <= landEnd {
            let landT = Float((p - handoff) / max(0.1, landEnd - handoff))
            out = aDual * (1 - landT)
        } else {
            out = 0
        }

        let inVol: Float
        if p <= invite {
            inVol = Float(p / invite) * 0.78
        } else if p < handoff {
            let t = Float((p - invite) / max(0.001, handoff - invite))
            inVol = 0.78 + 0.22 * t
        } else {
            inVol = 1
        }
        return (min(1, max(0, out)), min(1, max(0, inVol)))
    }

    private static func smoothstep(_ x: Double) -> Float {
        let t = min(1, max(0, x))
        return Float(t * t * (3 - 2 * t))
    }

    private static func mixMasterChunk(
        outgoing: AVAudioPCMBuffer,
        incoming: AVAudioPCMBuffer,
        output: AVAudioPCMBuffer,
        frames: AVAudioFrameCount,
        channelsA: Int,
        channelsB: Int,
        absoluteFrame: AVAudioFrameCount,
        totalFrames: AVAudioFrameCount,
        handoff: Double,
        hold: Double,
        lag: Double,
        beatmatched: Bool,
        useDuetVolumes: Bool = false
    ) {
        let aL = outgoing.floatChannelData?[0]
        let aR = channelsA > 1 ? outgoing.floatChannelData?[1] : aL
        let bL = incoming.floatChannelData?[0]
        let bR = channelsB > 1 ? incoming.floatChannelData?[1] : bL
        let oL = output.floatChannelData?[0]
        let oR = output.floatChannelData?[1]
        guard let aL, let aR, let bL, let bR, let oL, let oR else { return }

        let n = Int(frames)
        let denom = max(1, Double(totalFrames))
        for i in 0..<n {
            let progress = Double(absoluteFrame + AVAudioFrameCount(i)) / denom
            let vols = mashupVolumes(
                progress: progress,
                hold: hold,
                lag: lag,
                handoff: handoff,
                beatmatched: beatmatched,
                useDuetVolumes: useDuetVolumes
            )
            // Soft ceiling so A+B mashup floor doesn't clip the master.
            oL[i] = softClip(aL[i] * vols.outgoing + bL[i] * vols.incoming)
            oR[i] = softClip(aR[i] * vols.outgoing + bR[i] * vols.incoming)
        }
    }

    private static func softClip(_ x: Float) -> Float {
        let lim: Float = 0.98
        if x > lim { return lim + (x - lim) / (1 + (x - lim) * 4) }
        if x < -lim { return -lim + (x + lim) / (1 + (-x - lim) * 4) }
        return x
    }

    private static func copy(
        from input: AVAudioPCMBuffer,
        to output: AVAudioPCMBuffer,
        frames: AVAudioFrameCount,
        channels: Int
    ) {
        for c in 0..<max(1, min(channels, 2)) {
            guard let src = input.floatChannelData?[c],
                  let dst = output.floatChannelData?[c] else { continue }
            dst.update(from: src, count: Int(frames))
        }
    }

    private static func processChunk(
        input: AVAudioPCMBuffer,
        output: AVAudioPCMBuffer,
        frames: AVAudioFrameCount,
        channels: Int,
        mode: MidSideStemMode,
        amount: Float,
        absoluteFrame: AVAudioFrameCount,
        untilFrame: AVAudioFrameCount,
        fadeFrames: AVAudioFrameCount,
        midLp: inout Float,
        midBody: inout Float,
        midPres: inout Float,
        lpAlpha: Float,
        bodyAlpha: Float,
        presAlpha: Float
    ) {
        let left = input.floatChannelData?[0]
        let right = channels > 1 ? input.floatChannelData?[1] : left
        let oL = output.floatChannelData?[0]
        let oR = channels > 1 ? output.floatChannelData?[1] : oL
        guard let left, let right, let oL, let oR else { return }

        let a = amount
        let n = Int(frames)
        for i in 0..<n {
            let absFrame = absoluteFrame + AVAudioFrameCount(i)
            let l = left[i]
            let r = right[i]
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5
            // Lab karaoke carve: keep sub + body/air; notch lead presence only.
            midLp += lpAlpha * (mid - midLp)
            let midHi = mid - midLp
            midBody += bodyAlpha * (midHi - midBody)
            midPres += presAlpha * (midHi - midBody - midPres)

            let processedL: Float
            let processedR: Float
            switch mode {
            case .dry:
                processedL = l
                processedR = r
            case .instrumental:
                // Harder lead notch than Lab karaoke — dual-full Automix was muddy
                // when midPres leakage stacked with A vocal on device (field 1047).
                let midKeep =
                    midLp * (1 + 0.12 * a)
                    + midBody * (1 - 0.50 * a)
                    + midPres * (1 - 0.98 * a)
                let sideBoost = side * (1 + 0.38 * a)
                processedL = midKeep + sideBoost
                processedR = midKeep - sideBoost
            case .vocal:
                // A = center vocal isolate: drop sides + sub, keep lead presence.
                let midKeep =
                    midLp * (1 - 0.96 * a)
                    + midBody * (1 - 0.45 * a)
                    + midPres * (1 + 0.95 * a)
                let sideKeep = side * (1 - 0.98 * a)
                processedL = midKeep + sideKeep
                processedR = midKeep - sideKeep
            }

            // Instr→dry crossfade near LAND (B lead returns).
            if untilFrame > 0, mode == .instrumental {
                if absFrame >= untilFrame {
                    oL[i] = l
                    oR[i] = r
                } else if absFrame + fadeFrames >= untilFrame {
                    let start = untilFrame > fadeFrames ? untilFrame - fadeFrames : 0
                    let t = Float(absFrame - start) / Float(max(1, fadeFrames))
                    let ease = min(1, max(0, t))
                    let s = ease * ease * (3 - 2 * ease)
                    let a = cos(s * Float.pi * 0.5)
                    let b = sin(s * Float.pi * 0.5)
                    oL[i] = processedL * a + l * b
                    oR[i] = processedR * a + r * b
                } else {
                    oL[i] = processedL
                    oR[i] = processedR
                }
            } else {
                oL[i] = processedL
                oR[i] = processedR
            }
        }
    }
}

/// Pulls compressed frames into an AVAudioConverter without escaping the decode queue.
private final class Float32DecodeCursor: @unchecked Sendable {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    private var eof = false

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(_ statusPtr: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if eof {
            statusPtr.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                eof = true
                statusPtr.pointee = .endOfStream
                return nil
            }
            statusPtr.pointee = .haveData
            return buffer
        } catch {
            eof = true
            statusPtr.pointee = .endOfStream
            return nil
        }
    }
}
