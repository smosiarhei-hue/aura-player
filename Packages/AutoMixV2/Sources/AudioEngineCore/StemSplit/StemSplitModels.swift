import AVFAudio
import Foundation

public enum StemKind: String, CaseIterable, Sendable {
    case vocals
    case drums
    case bass
    case other
}

public struct StereoChunk: Sendable {
    public var left: [Float]
    public var right: [Float]
    public var frameCount: Int { left.count }

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }
}

public struct SeparatedBlock: Sendable {
    public var stems: [StemKind: StereoChunk]
    public var frameCount: Int

    public init(stems: [StemKind: StereoChunk], frameCount: Int) {
        self.stems = stems
        self.frameCount = frameCount
    }
}

public enum PipelineError: Error, Sendable {
    case modelNotFound
    case unsupportedModel
    case converterFailed
}

public protocol PCMSource: Sendable {
    var sampleRate: Double { get }
    var totalFrames: AVAudioFramePosition { get }
    func read(start: AVAudioFramePosition, count: AVAudioFrameCount) async throws -> StereoChunk
}

public protocol StemSeparating: Sendable {
    var segmentFrames: Int { get }
    func separate(_ input: StereoChunk) async throws -> [StemKind: StereoChunk]
}
