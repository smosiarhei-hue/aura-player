import AVFAudio
import Foundation

public actor SeparationPipeline {
    private let source: any PCMSource
    private let separator: any StemSeparating
    private var assembler: OverlapAddAssembler
    private var nextSegment = 0
    private var emitted: AVAudioFramePosition = 0

    public init(source: any PCMSource, separator: any StemSeparating) {
        self.source = source
        self.separator = separator
        self.assembler = OverlapAddAssembler(segment: separator.segmentFrames)
    }

    public func nextBlock() async throws -> SeparatedBlock? {
        let total = source.totalFrames
        guard emitted < total else { return nil }
        let segment = separator.segmentFrames
        let hop = segment / 2

        while true {
            let k = nextSegment
            nextSegment += 1
            let start = AVAudioFramePosition(k - 1) * AVAudioFramePosition(hop)
            let input = try await source.read(start: start, count: AVAudioFrameCount(segment))
            let stems = try await separator.separate(input)
            assembler.add(stems)
            guard k > 0 else { continue }
            let count = min(hop, Int(total - emitted))
            let ready = assembler.ready(count: count)
            assembler.shift()
            emitted += AVAudioFramePosition(count)
            return SeparatedBlock(stems: ready, frameCount: count)
        }
    }
}
