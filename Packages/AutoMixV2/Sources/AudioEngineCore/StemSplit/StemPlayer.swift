import AVFoundation
import Foundation

@MainActor
public final class StemPlayer {
    public var onTime: ((Double) -> Void)?
    private let engine = AVAudioEngine()
    private let nodes: [StemKind: AVAudioPlayerNode]
    private let format: AVAudioFormat
    private var queued = 0
    private var playing = false
    private var renderedFrames: AVAudioFramePosition = 0
    private let pipeline: SeparationPipeline

    public init(pipeline: SeparationPipeline) {
        self.pipeline = pipeline
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        var made: [StemKind: AVAudioPlayerNode] = [:]
        for kind in StemKind.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            made[kind] = node
        }
        self.nodes = made
    }

    public func setGain(_ kind: StemKind, _ value: Float) {
        nodes[kind]?.volume = value
    }

    public func play() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        nodes.values.forEach { $0.play() }
        playing = true
        Task { await fill() }
    }

    public func stop() {
        playing = false
        nodes.values.forEach { $0.stop() }
        engine.stop()
    }

    private func fill() async {
        while playing && queued < 2 {
            guard let block = try? await pipeline.nextBlock() else { return }
            schedule(block)
            queued += 1
        }
    }

    private func schedule(_ block: SeparatedBlock) {
        for kind in StemKind.allCases {
            guard let chunk = block.stems[kind],
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.frameCount)),
                  let ch = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(block.frameCount)
            for i in 0..<block.frameCount {
                ch[0][i] = chunk.left[i]
                ch[1][i] = chunk.right[i]
            }
            nodes[kind]?.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard kind == .vocals else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.queued -= 1
                    self.renderedFrames += AVAudioFramePosition(block.frameCount)
                    self.onTime?(Double(self.renderedFrames) / 44_100)
                    await self.fill()
                }
            }
        }
    }
}
