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

    @Test("ONE VOCAL pair: A instrumental, B instrumental until handoff then dry")
    func oneVocalPair() throws {
        let dir = try temporaryBakeDirectory()
        defer { removeBakeItem(at: dir) }
        let a = try makeStereoTone(in: dir, name: "a.caf", rate: 44_100, duration: 30)
        let b = try makeStereoTone(in: dir, name: "b.caf", rate: 44_100, duration: 30)
        let pair = try MidSideStemBaker.bakeOneVocalPair(
            outgoingURL: a,
            incomingURL: b,
            cueA: 10,
            cueB: 5,
            blendSec: 8,
            handoffProgress: 0.55
        )
        defer { MidSideStemBaker.removeTempFiles([pair.outgoing, pair.incoming]) }

        let outA = try AVAudioFile(forReading: pair.outgoing)
        let outB = try AVAudioFile(forReading: pair.incoming)
        let secA = Double(outA.length) / outA.processingFormat.sampleRate
        let secB = Double(outB.length) / outB.processingFormat.sampleRate
        #expect(secA >= 7)
        #expect(secA <= MidSideStemBaker.maximumDurationSec + 1.5)
        #expect(secB >= 7)
        #expect(abs(secA - secB) < 1.0)
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
                // Center-panned lead (mid) + side pad — gives Mid/Side something to carve.
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
