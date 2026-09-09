// Path: Packages/AutoMixV2/Sources/TrackAnalysis/PulseTempoEstimator.swift

import Foundation

public enum PulseTempoEstimator {
    /// High-resolution transient-period estimator used to refine synthetic and
    /// strongly percussive material after the broad autocorrelation search.
    public static func estimate(samples: [Float], sampleRate: Double) -> (bpm: Float, confidence: Float) {
        guard sampleRate > 0, samples.count > Int(sampleRate) else { return (0, 0) }
        let peak = samples.lazy.map { abs($0) }.max() ?? 0
        guard peak > 0 else { return (0, 0) }
        let threshold = max(peak * 0.35, 0.02)
        let refractory = Int(sampleRate * 0.20)
        var transients: [Int] = []
        var last = -refractory
        var wasBelow = true
        for index in samples.indices {
            let value = abs(samples[index])
            if value >= threshold, wasBelow, index - last >= refractory {
                transients.append(index)
                last = index
            }
            wasBelow = value < threshold * 0.5
        }
        guard transients.count >= 8 else { return (0, 0) }
        let intervals = zip(transients, transients.dropFirst()).map { Double($1 - $0) / sampleRate }.sorted()
        let median = intervals[intervals.count / 2]
        guard median > 0 else { return (0, 0) }
        var bpm = 60 / median
        while bpm < 70 { bpm *= 2 }
        while bpm > 190 { bpm /= 2 }
        let deviations = intervals.map { abs($0 - median) / median }.sorted()
        let medianDeviation = deviations[deviations.count / 2]
        let confidence = Float(min(1, max(0, 1 - medianDeviation * 8)))
        return (Float(bpm), confidence)
    }
}
