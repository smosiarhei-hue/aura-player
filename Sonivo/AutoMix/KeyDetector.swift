import Foundation

// MARK: - Key detection
//
// Krumhansl-Kessler template matching over the accumulated chroma vector:
// 24 candidates (12 pitch classes x major/minor), Pearson correlation.

nonisolated enum KeyDetector {
    nonisolated private static let majorProfile: [Float] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 5.19, 2.39, 3.66, 2.29, 2.88, 2.19
    ]

    nonisolated private static let minorProfile: [Float] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]

    nonisolated static func detect(chroma: [Float]) -> MusicalKey {
        guard chroma.count == 12, (chroma.max() ?? 0) > 0 else {
            return MusicalKey(pitchClass: 0, mode: .major, confidence: 0)
        }

        var best = MusicalKey(pitchClass: 0, mode: .major, confidence: 0)
        var bestScore = -Float.greatestFiniteMagnitude

        for pitchClass in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + pitchClass) % 12] }

            let majorScore = correlation(rotated, majorProfile)
            if majorScore > bestScore {
                bestScore = majorScore
                best = MusicalKey(
                    pitchClass: pitchClass,
                    mode: .major,
                    confidence: max(0, min(1, majorScore))
                )
            }

            let minorScore = correlation(rotated, minorProfile)
            if minorScore > bestScore {
                bestScore = minorScore
                best = MusicalKey(
                    pitchClass: pitchClass,
                    mode: .minor,
                    confidence: max(0, min(1, minorScore))
                )
            }
        }

        return best
    }

    nonisolated private static func correlation(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else { return 0 }
        let count = Float(first.count)
        let firstMean = first.reduce(0, +) / count
        let secondMean = second.reduce(0, +) / count

        var covariance: Float = 0
        var firstVariance: Float = 0
        var secondVariance: Float = 0
        for index in first.indices {
            let a = first[index] - firstMean
            let b = second[index] - secondMean
            covariance += a * b
            firstVariance += a * a
            secondVariance += b * b
        }

        let denominator = (firstVariance * secondVariance).squareRoot()
        guard denominator > 0 else { return 0 }
        return covariance / denominator
    }
}
