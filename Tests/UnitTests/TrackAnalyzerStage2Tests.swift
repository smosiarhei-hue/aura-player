// Path: Tests/UnitTests/TrackAnalyzerStage2Tests.swift

import Foundation
import MixModels
import Testing
import TrackAnalysis

@Suite("TrackAnalyzer Stage 2")
struct TrackAnalyzerStage2Tests {
    @Test("Synthetic click tempos stay within one BPM", arguments: [90.0, 120.0, 128.0, 174.0])
    func clickTempo(expected: Double) {
        let sampleRate = 22_050.0
        let duration = 40.0
        var samples = Array(repeating: Float(0), count: Int(sampleRate * duration))
        let period = 60.0 / expected
        var time = 0.0
        while time < duration {
            let start = Int(time * sampleRate)
            for offset in 0..<min(220, samples.count - start) {
                samples[start + offset] += Float(exp(-Double(offset) / 35.0))
            }
            time += period
        }
        var state: UInt64 = 0x12345678
        for index in samples.indices {
            state = state &* 6364136223846793005 &+ 1
            let noise = Float(Int(state >> 48) - 32_768) / 32_768 * 0.002
            samples[index] += noise
        }
        let result = TrackAnalysisAlgorithms.estimateTempo(samples: samples, sampleRate: sampleRate)
        let direct = abs(Double(result.bpm) - expected)
        let doubled = abs(Double(result.bpm) * 2 - expected)
        let halved = abs(Double(result.bpm) / 2 - expected)
        #expect(min(direct, doubled, halved) <= 1)
        #expect(result.confidence >= 0.7)
    }
}
