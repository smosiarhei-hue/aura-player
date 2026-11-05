// Path: Packages/AutoMixV2/Sources/AudioEngineCore/MoodEnergyProbe.swift
//
// One-second loudness of the outro and the intro. AutoMix uses it to choose
// the blend instead of a fixed 8s / 16s cue. The read is the same private
// copy path as the stem bake, so a live AVPlayer cache does not block it.

import AVFAudio
import Foundation

public struct MoodEnergyBins: Sendable, Equatable {
    public let outgoingDuration: Double
    public let incomingDuration: Double
    /// Per second, oldest first. Covers the end of the outgoing track.
    public let outgoingTail: [Float]
    /// Per second from the start of the incoming track.
    public let incomingHead: [Float]
}

public enum MoodEnergyProbe {
    public static func bins(outgoingURL: URL, incomingURL: URL) -> MoodEnergyBins? {
        guard let tail = try? envelope(url: outgoingURL, seconds: 36, fromEnd: true),
              let head = try? envelope(url: incomingURL, seconds: 28, fromEnd: false),
              tail.bins.count >= 6, head.bins.count >= 4 else { return nil }
        return MoodEnergyBins(
            outgoingDuration: tail.duration,
            incomingDuration: head.duration,
            outgoingTail: tail.bins,
            incomingHead: head.bins
        )
    }

    private static func envelope(
        url: URL,
        seconds: Double,
        fromEnd: Bool
    ) throws -> (bins: [Float], duration: Double) {
        let scratch: URL?
        let measured: (bins: [Float], duration: Double)
        do {
            let opened = try MidSideStemBaker.openFloat32Source(url)
            scratch = opened.scratch
            measured = try measure(file: opened.file, seconds: seconds, fromEnd: fromEnd)
        }
        if let scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        return measured
    }

    private static func measure(
        file: AVAudioFile,
        seconds: Double,
        fromEnd: Bool
    ) throws -> (bins: [Float], duration: Double) {
        let rate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        guard rate > 8_000, channels > 0, file.length > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let duration = Double(file.length) / rate
        let window = min(seconds, duration)
        let start = fromEnd ? max(0, duration - window) : 0
        file.framePosition = AVAudioFramePosition(start * rate)
        let framesWanted = AVAudioFramePosition(window * rate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: 8_192
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var sums = [Double](repeating: 0, count: max(1, Int(ceil(window))))
        var counts = [Int](repeating: 0, count: sums.count)
        var read: AVAudioFramePosition = 0
        while read < framesWanted {
            let chunk = AVAudioFrameCount(min(AVAudioFramePosition(8_192), framesWanted - read))
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channelsData = buffer.floatChannelData else { break }
            let useChannels = min(channels, Int(buffer.format.channelCount))
            for frame in 0..<frames {
                var square = 0.0
                for channel in 0..<useChannels {
                    let sample = Double(channelsData[channel][frame])
                    square += sample * sample
                }
                let second = Int((read + AVAudioFramePosition(frame)) / AVAudioFramePosition(rate))
                if sums.indices.contains(second) {
                    sums[second] += square / Double(max(1, useChannels))
                    counts[second] += 1
                }
            }
            read += AVAudioFramePosition(frames)
        }

        var raw: [Float] = []
        raw.reserveCapacity(sums.count)
        for index in sums.indices where counts[index] > 0 {
            raw.append(Float(sqrt(sums[index] / Double(counts[index]))))
        }
        return (normalize(raw), duration)
    }

    private static func normalize(_ raw: [Float]) -> [Float] {
        guard !raw.isEmpty else { return [] }
        let sorted = raw.sorted()
        let peak = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let scale = max(peak, 1e-8)
        return raw.map { min(1, max(0, $0 / scale)) }
    }
}
