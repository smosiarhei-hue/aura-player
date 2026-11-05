import AVFAudio
import Foundation

public actor FileAudioSource: PCMSource {
    public nonisolated let sampleRate: Double = 44_100
    public nonisolated let totalFrames: AVAudioFramePosition
    private let file: AVAudioFile

    public init(url: URL) throws {
        self.file = try AVAudioFile(forReading: url)
        self.totalFrames = file.length
    }

    public func read(start: AVAudioFramePosition, count: AVAudioFrameCount) async throws -> StereoChunk {
        var left = [Float](repeating: 0, count: Int(count))
        var right = [Float](repeating: 0, count: Int(count))
        let fileStart = max(0, start)
        let lead = Int(fileStart - start)
        let available = max(0, Int(totalFrames - fileStart))
        let n = min(Int(count) - lead, available)
        guard n > 0 else { return StereoChunk(left: left, right: right) }
        file.framePosition = fileStart
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else {
            throw PipelineError.converterFailed
        }
        try file.read(into: buf, frameCount: AVAudioFrameCount(n))
        let channels = Int(buf.format.channelCount)
        if let ch = buf.floatChannelData {
            for i in 0..<n {
                left[lead + i] = ch[0][i]
                right[lead + i] = channels > 1 ? ch[1][i] : ch[0][i]
            }
        }
        return StereoChunk(left: left, right: right)
    }
}

/// PCM the app already decoded (a cached window, not a live encrypted stream).
public struct MemoryPCMSource: PCMSource {
    public let sampleRate: Double = 44_100
    public let totalFrames: AVAudioFramePosition
    private let left: [Float]
    private let right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
        self.totalFrames = AVAudioFramePosition(left.count)
    }

    public func read(start: AVAudioFramePosition, count: AVAudioFrameCount) async throws -> StereoChunk {
        var l = [Float](repeating: 0, count: Int(count))
        var r = [Float](repeating: 0, count: Int(count))
        let from = Int(start)
        for i in 0..<Int(count) {
            let p = from + i
            if p >= 0 && p < left.count {
                l[i] = left[p]
                r[i] = right[p]
            }
        }
        return StereoChunk(left: l, right: r)
    }
}
