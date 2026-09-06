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
}
