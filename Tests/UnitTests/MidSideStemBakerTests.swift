// Path: Tests/UnitTests/MidSideStemBakerTests.swift

@preconcurrency import AVFAudio
import AudioEngineCore
import Foundation
import Testing

@Suite("Mid/Side stem baker (window-only, chunked)")
struct MidSideStemBakerTests {
    @Test("Bake writes only the mashup window to a temp CAF")
    func bakesWindowOnly() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let source = try makeStereoTone(in: dir, rate: 44_100, duration: 12)
        let out = try MidSideStemBaker.bakeToTempFile(
            MidSideBakeRequest(
                fileURL: source,
                cueSec: 2,
                durationSec: 4,
                mode: .instrumental,
                amount: 1
            )
        )
        defer { MidSideStemBaker.removeTempFiles([out]) }

        let baked = try AVAudioFile(forReading: out)
        let seconds = Double(baked.length) / baked.processingFormat.sampleRate
        #expect(seconds >= 3.5)
        #expect(seconds <= 5.5)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }

    @Test("Duration is hard-capped so a bad cue cannot allocate a huge bake")
    func capsDuration() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let source = try makeStereoTone(in: dir, rate: 44_100, duration: 90)
        let out = try MidSideStemBaker.bakeToTempFile(
            MidSideBakeRequest(
                fileURL: source,
                cueSec: 0,
                durationSec: 120,
                mode: .dry
            )
        )
        defer { MidSideStemBaker.removeTempFiles([out]) }

        let baked = try AVAudioFile(forReading: out)
        let seconds = Double(baked.length) / baked.processingFormat.sampleRate
        #expect(seconds <= MidSideStemBaker.maximumDurationSec + 1.5)
    }

    @Test("ONE VOCAL master: one stereo CAF of A+B for the mashup window")
    func oneVocalMaster() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let a = try makeStereoTone(in: dir, name: "a.caf", rate: 44_100, duration: 30)
        let b = try makeStereoTone(in: dir, name: "b.caf", rate: 44_100, duration: 30)
        let master = try MidSideStemBaker.bakeOneVocalMaster(
            outgoingURL: a,
            incomingURL: b,
            cueA: 10,
            cueB: 5,
            blendSec: 8,
            handoffProgress: 0.55,
            outgoingVolumeHold: 0.42,
            incomingVolumeLag: 0.18,
            isBeatmatched: true
        )
        defer { MidSideStemBaker.removeTempFiles([master]) }

        let file = try AVAudioFile(forReading: master)
        let sec = Double(file.length) / file.processingFormat.sampleRate
        #expect(file.processingFormat.channelCount == 2)
        #expect(sec >= 7)
        #expect(sec <= MidSideStemBaker.maximumDurationSec + 1.5)
        #expect(FileManager.default.fileExists(atPath: master.path))
    }

    @Test("Duet master: A vocal + B dry for the mashup window")
    func duetMaster() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let a = try makeStereoTone(in: dir, name: "duet-a.caf", rate: 44_100, duration: 30)
        let b = try makeStereoTone(in: dir, name: "duet-b.caf", rate: 44_100, duration: 30)
        let master = try MidSideStemBaker.bakeDuetMaster(
            outgoingURL: a,
            incomingURL: b,
            cueA: 12,
            cueB: 4,
            blendSec: 10,
            handoffProgress: 0.68,
            outgoingVolumeHold: 0.86,
            incomingVolumeLag: 0.1,
            isBeatmatched: true
        )
        defer { MidSideStemBaker.removeTempFiles([master]) }

        let file = try AVAudioFile(forReading: master)
        let sec = Double(file.length) / file.processingFormat.sampleRate
        #expect(file.processingFormat.channelCount == 2)
        #expect(sec >= 8)
        #expect(sec <= MidSideStemBaker.maximumDurationSec + 1.5)
        #expect(FileManager.default.fileExists(atPath: master.path))
    }

    @Test("Hybrid separator cancels center lead more than sides")
    func hybridInstrumentalAttenuatesCenter() {
        let frames = 2_048
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / 44_100
            // Center lead (~1 kHz) + stereo side pad (~330 Hz).
            let mid = 0.45 * sin(2 * Float.pi * 1_000 * t)
            let side = 0.20 * sin(2 * Float.pi * 330 * t)
            left[i] = mid + side
            right[i] = mid - side
        }
        let dryMidEnergy = (0..<frames).reduce(Float(0)) { partial, i in
            let mid = (left[i] + right[i]) * 0.5
            return partial + mid * mid
        }
        var state = StemSeparator.State()
        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                StemSeparator.renderHybridInstrumental(
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!,
                    frames: frames,
                    amount: 1,
                    sampleRate: 48_000,
                    state: &state
                )
            }
        }
        let outMidEnergy = (0..<frames).reduce(Float(0)) { partial, i in
            let mid = (left[i] + right[i]) * 0.5
            return partial + mid * mid
        }
        // Lab-style bed: soft formant tuck, not nuclear mid-mute (keeps groove body).
        #expect(outMidEnergy < dryMidEnergy * 0.92)
        #expect(outMidEnergy > dryMidEnergy * 0.25)
    }

    @Test("Automix stem pair reports a separation backend")
    func automixPairSetsBackend() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let a = try makeStereoTone(in: dir, name: "sep-a.caf", rate: 44_100, duration: 20)
        let b = try makeStereoTone(in: dir, name: "sep-b.caf", rate: 44_100, duration: 20)
        let pair = try MidSideStemBaker.bakeAutomixStemPair(
            outgoingURL: a,
            incomingURL: b,
            cueA: 2,
            cueB: 1,
            blendSec: 6,
            handoffProgress: 0.9,
            padSec: 1
        )
        defer { MidSideStemBaker.removeTempFiles([pair.outgoing, pair.incoming]) }
        let backend = MidSideStemBaker.lastSeparationBackend
        #expect(backend == .hybridSpectral || backend == .soundIsolation)
        #expect(FileManager.default.fileExists(atPath: pair.outgoing.path))
        #expect(FileManager.default.fileExists(atPath: pair.incoming.path))
    }

    @Test("removeTempFiles deletes baked CAF slices")
    func removesTemps() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let source = try makeStereoTone(in: dir, rate: 44_100, duration: 3)
        let out = try MidSideStemBaker.bakeToTempFile(
            MidSideBakeRequest(fileURL: source, cueSec: 0, durationSec: 2, mode: .vocal)
        )
        #expect(FileManager.default.fileExists(atPath: out.path))
        MidSideStemBaker.removeTempFiles([out])
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("Playback open returns a readable float32 file for a local CAF")
    func openPlaybackSourceReadsCAF() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let source = try makeStereoTone(in: dir, name: "play.caf", rate: 44_100, duration: 2)
        let opened = try MidSideStemBaker.openPlaybackSource(source)
        defer {
            if let scratch = opened.scratch {
                MidSideStemBaker.removeTempFiles([scratch])
            }
        }
        #expect(opened.file.length > 0)
        #expect(opened.scratch == nil)
    }

    @Test("Float32 CAF decode round-trips a local tone")
    func decodeCompressedRoundTrip() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let source = try makeStereoTone(in: dir, name: "decode.caf", rate: 44_100, duration: 1.5)
        let caf = try MidSideStemBaker.decodeCompressedToFloat32CAF(source)
        defer { MidSideStemBaker.removeTempFiles([caf]) }
        let file = try AVAudioFile(forReading: caf)
        #expect(file.length > 0)
        #expect(file.processingFormat.commonFormat == .pcmFormatFloat32)
        #expect(!file.processingFormat.isInterleaved)
    }
}

private func temporaryBakeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-bake-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeBakeItem(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func makeStereoTone(
    in directory: URL,
    name: String = "tone.caf",
    rate: Double,
    duration: Double
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try autoreleasepool {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)
        )
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        let channels = try #require(buffer.floatChannelData)
        let left = channels[0]
        let right = channels[1]
        let totalFrames = Int(rate * duration)
        var offset = 0
        while offset < totalFrames {
            let count = min(4_096, totalFrames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let t = Double(offset + index) / rate
                let mid = Float(0.25 * sin(2 * Double.pi * 880 * t))
                let side = Float(0.12 * sin(2 * Double.pi * 220 * t))
                left[index] = mid + side
                right[index] = mid - side
            }
            try writer.write(from: buffer)
            offset += count
        }
    }
    return url
}
