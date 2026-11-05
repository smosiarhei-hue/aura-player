// Path: Tests/UnitTests/AudioEngineCoreTests.swift

import AudioEngineCore
import Testing

@Suite("AutoMixV2 audio engine core")
struct AudioEngineCoreTests {
    @Test("S-curve has exact endpoints and a smooth midpoint")
    func sCurve() {
        let start = CrossfadeCurve.gains(progress: 0)
        let middle = CrossfadeCurve.gains(progress: 0.5)
        let end = CrossfadeCurve.gains(progress: 1)

        #expect(start.outgoing == 1)
        #expect(start.incoming == 0)
        #expect(middle.outgoing == 0.5)
        #expect(middle.incoming == 0.5)
        #expect(end.outgoing == 0)
        #expect(end.incoming == 1)
    }

    @Test("Default PCM preload stays within the 25 MB budget")
    func preloadBudget() {
        let policy = PCMPreloadPolicy()

        #expect(policy.sampleRate == 48_000)
        #expect(policy.channels == 2)
        #expect(policy.estimatedTotalQueuedBytes == 23_040_000)
        #expect(policy.estimatedTotalQueuedBytes <= PCMPreloadPolicy.maximumTotalBytes)
    }

    @Test("Invalid oversized preload policy is rejected")
    func rejectsOversizedPreload() {
        let policy = PCMPreloadPolicy(queuedDurationPerDeckSeconds: 120)

        #expect(throws: AudioEngineCoreError.unsupportedOutputFormat) {
            _ = try DualDeckAudioEngine(preloadPolicy: policy)
        }
    }

    @Test("Passthrough overlap-add restores the mix and leaves vocals silent")
    func passthroughRestoresInput() async throws {
        let n = 900_000
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        for i in 0..<n {
            left[i] = sin(Float(i) * 0.01)
            right[i] = cos(Float(i) * 0.013)
        }
        let pipeline = SeparationPipeline(
            source: MemoryPCMSource(left: left, right: right),
            separator: PassthroughSeparator()
        )
        var gotL: [Float] = []
        var gotR: [Float] = []
        while let block = try await pipeline.nextBlock() {
            let other = try #require(block.stems[.other])
            gotL.append(contentsOf: other.left)
            gotR.append(contentsOf: other.right)
            for kind in [StemKind.vocals, .drums, .bass] {
                let chunk = try #require(block.stems[kind])
                #expect(chunk.left.allSatisfy { $0 == 0 })
                #expect(chunk.right.allSatisfy { $0 == 0 })
            }
        }
        #expect(gotL.count == n)
        var maxErr: Float = 0
        for i in 0..<n {
            maxErr = max(maxErr, abs(gotL[i] - left[i]), abs(gotR[i] - right[i]))
        }
        #expect(maxErr < 1e-4)
    }
}
