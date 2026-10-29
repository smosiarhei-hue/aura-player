// Path: Packages/AutoMixV2/Sources/AudioEngineCore/MidSideStemBaker.swift
//
// Lab-style Mid/Side instrumentalize — memory-light:
// only the mashup window is read, processed in small chunks, and written to a
// temp CAF on disk. Peak RAM ≈ one chunk (~64 KB), not the full track.

@preconcurrency import AVFAudio
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
    /// When > 0 and mode == .instrumental: crossfade into dry lead after this many seconds
    /// (ONE VOCAL: B instrumental until LAND, then dry).
    public var instrumentalUntilSec: Double

    public init(
        fileURL: URL,
        cueSec: Double,
        durationSec: Double,
        mode: MidSideStemMode,
        amount: Float = 1,
        instrumentalUntilSec: Double = 0
    ) {
        self.fileURL = fileURL
        self.cueSec = cueSec
        self.durationSec = durationSec
        self.mode = mode
        self.amount = amount
        self.instrumentalUntilSec = instrumentalUntilSec
    }
}

public enum MidSideStemBaker {
    /// Soft cap so a bad cue can't allocate a huge bake (Lab blend ≤ ~36s).
    public static let maximumDurationSec: Double = 40
    private static let chunkFrames: AVAudioFrameCount = 4_096

    /// Bake one mashup slice to a temp CAF. Caller must delete the URL when done.
    public static func bakeToTempFile(_ request: MidSideBakeRequest) throws -> URL {
        let duration = min(maximumDurationSec, max(1, request.durationSec))
        let cue = max(0, request.cueSec)
        let amount = min(1, max(0, request.amount))
        let until = min(duration, max(0, request.instrumentalUntilSec))

        let source = try AVAudioFile(forReading: request.fileURL)
        let format = source.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, source.length > 0 else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }

        let startFrame = min(source.length - 1, AVAudioFramePosition(cue * rate))
        let maxFrames = source.length - startFrame
        let availableSec = Double(maxFrames) / rate
        let wantSec = min(duration + 1.0, availableSec)
        let wantFrames = AVAudioFramePosition(wantSec * rate)
        let totalFrames = AVAudioFrameCount(min(maxFrames, max(1, wantFrames)))
        let untilFrame = AVAudioFrameCount(min(Double(totalFrames), until * rate))

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonivo-mashup-\(UUID().uuidString).caf")
        let output = try AVAudioFile(forWriting: outURL, settings: format.settings)

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            try? FileManager.default.removeItem(at: outURL)
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }

        source.framePosition = startFrame
        var written: AVAudioFrameCount = 0
        var midLp: Float = 0
        var midBp: Float = 0
        let lpAlpha = Float(1 - exp(-2 * Double.pi * 180 / rate))
        let bpAlpha = Float(1 - exp(-2 * Double.pi * 2500 / rate))
        let channels = Int(format.channelCount)
        let fadeFrames = AVAudioFrameCount(max(1, Int(0.08 * rate)))

        // Chunked read→process→write: never materialize the whole window in RAM.
        // autoreleasepool drains AVFoundation temps per chunk on Apple platforms.
        while written < totalFrames {
            let got: AVAudioFrameCount = try autoreleasepool {
                let n = min(chunkFrames, totalFrames - written)
                inBuf.frameLength = 0
                try source.read(into: inBuf, frameCount: n)
                let got = inBuf.frameLength
                guard got > 0 else { return 0 }
                outBuf.frameLength = got

                let mode = request.mode
                if mode == .dry || amount < 0.05 {
                    copy(from: inBuf, to: outBuf, frames: got, channels: channels)
                } else {
                    processChunk(
                        input: inBuf,
                        output: outBuf,
                        frames: got,
                        channels: channels,
                        mode: mode,
                        amount: amount,
                        absoluteFrame: written,
                        untilFrame: untilFrame,
                        fadeFrames: fadeFrames,
                        midLp: &midLp,
                        midBp: &midBp,
                        lpAlpha: lpAlpha,
                        bpAlpha: bpAlpha
                    )
                }

                try output.write(from: outBuf)
                return got
            }
            guard got > 0 else { break }
            written += got
            if got < chunkFrames && written < totalFrames {
                // Short read near EOF — stop rather than spin.
                if source.framePosition >= source.length { break }
            }
        }

        return outURL
    }

    /// Bake A instrumental + B instrumental→dry for ONE VOCAL mashup. Temp files only.
    public static func bakeOneVocalPair(
        outgoingURL: URL,
        incomingURL: URL,
        cueA: Double,
        cueB: Double,
        blendSec: Double,
        handoffProgress: Double
    ) throws -> (outgoing: URL, incoming: URL) {
        let blend = min(maximumDurationSec, max(4, blendSec))
        let handoff = min(0.85, max(0.35, handoffProgress))
        let a = try bakeToTempFile(
            MidSideBakeRequest(
                fileURL: outgoingURL,
                cueSec: cueA,
                durationSec: blend,
                mode: .instrumental,
                amount: 1,
                instrumentalUntilSec: 0
            )
        )
        do {
            let b = try bakeToTempFile(
                MidSideBakeRequest(
                    fileURL: incomingURL,
                    cueSec: cueB,
                    durationSec: blend,
                    mode: .instrumental,
                    amount: 1,
                    instrumentalUntilSec: blend * handoff
                )
            )
            return (a, b)
        } catch {
            try? FileManager.default.removeItem(at: a)
            throw error
        }
    }

    public static func removeTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - DSP

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
        if channels == 1, let src = input.floatChannelData?[0], let dst = output.floatChannelData?[0] {
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
        midBp: inout Float,
        lpAlpha: Float,
        bpAlpha: Float
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
            midLp += lpAlpha * (mid - midLp)
            midBp += bpAlpha * (mid - midLp - midBp)

            let processedL: Float
            let processedR: Float
            switch mode {
            case .dry:
                processedL = l
                processedR = r
            case .instrumental:
                let midVocal = mid - midLp
                let midKeep = midLp * (1 + 0.1 * a) + midVocal * (1 - 0.999 * a) - midBp * 0.85 * a
                let sideBoost = side * (1 + 0.35 * a)
                processedL = midKeep + sideBoost
                processedR = midKeep - sideBoost
            case .vocal:
                let sideKeep = side * (1 - 0.9 * a)
                let midBoost = mid * (1 + 0.12 * a)
                processedL = midBoost + sideKeep
                processedR = midBoost - sideKeep
            }

            // Instr→dry crossfade near LAND (B lead returns).
            if untilFrame > 0, mode == .instrumental {
                if absFrame >= untilFrame {
                    oL[i] = l
                    oR[i] = r
                } else if absFrame + fadeFrames >= untilFrame {
                    let start = untilFrame > fadeFrames ? untilFrame - fadeFrames : 0
                    let t = Float(absFrame - start) / Float(max(1, fadeFrames))
                    let w = min(1, max(0, t))
                    oL[i] = processedL * (1 - w) + l * w
                    oR[i] = processedR * (1 - w) + r * w
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
