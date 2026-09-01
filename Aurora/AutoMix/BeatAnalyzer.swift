import Foundation

// MARK: - Tempo, beat grid and downbeats
//
// Onset envelope -> autocorrelation tempo -> double/half-time sanity check ->
// phase search -> beat-by-beat tracking with drift correction -> downbeats.

nonisolated struct BeatResult: Sendable {
    var bpm: Double
    /// 0...1, low for material without a clear pulse (ballads, spoken word).
    var confidence: Float
    var beatGrid: [TimeInterval]
    var downbeats: [TimeInterval]

    static let empty = BeatResult(bpm: 0, confidence: 0, beatGrid: [], downbeats: [])
}

nonisolated enum BeatAnalyzer {
    /// Typical dance/pop tempo range, used to resolve double/half-time errors.
    static let preferredRange: ClosedRange<Double> = 85...175

    nonisolated static func analyze(features: AudioFeatures) -> BeatResult {
        let fps = features.frameRate
        guard fps > 0 else { return .empty }

        let envelope = whitened(features.onset)
        guard envelope.count > Int(fps * 8) else { return .empty }
        guard let tempo = estimateTempo(envelope: envelope, fps: fps) else { return .empty }

        let period = 60.0 / tempo.bpm * fps
        let beats = trackBeats(envelope: envelope, period: period, fps: fps)
        let confidence = confidence(envelope: envelope, beats: beats, fps: fps, autocorrelation: tempo.score)
        let downbeats = detectDownbeats(envelope: envelope, beats: beats, fps: fps)

        return BeatResult(bpm: tempo.bpm, confidence: confidence, beatGrid: beats, downbeats: downbeats)
    }

    // MARK: - Onset envelope

    /// Adaptive whitening: subtract a half-second running mean, keep the peaks.
    nonisolated private static func whitened(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return [] }
        let windowSize = 43
        var result = [Float](repeating: 0, count: values.count)
        var queue: [Float] = []
        var runningSum: Float = 0

        for index in values.indices {
            queue.append(values[index])
            runningSum += values[index]
            if queue.count > windowSize {
                runningSum -= queue.removeFirst()
            }
            let mean = runningSum / Float(queue.count)
            result[index] = max(0, values[index] - mean)
        }

        let peak = result.max() ?? 0
        guard peak > 0 else { return result }
        return result.map { $0 / peak }
    }

    // MARK: - Tempo

    nonisolated private struct Tempo: Sendable {
        var bpm: Double
        var score: Float
    }

    nonisolated private static func estimateTempo(envelope: [Float], fps: Double) -> Tempo? {
        let minLag = max(2, Int(fps * 60.0 / 200.0))
        let maxLag = min(envelope.count / 2, Int(fps * 60.0 / 60.0))
        guard maxLag > minLag else { return nil }

        let mean = envelope.reduce(0, +) / Float(envelope.count)
        let centred = envelope.map { $0 - mean }
        var zeroLag: Float = 0
        for value in centred { zeroLag += value * value }
        guard zeroLag > 0 else { return nil }

        var scores = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var sum: Float = 0
            var index = 0
            while index + lag < centred.count {
                sum += centred[index] * centred[index + lag]
                index += 1
            }
            scores[lag] = sum / zeroLag
        }

        var bestLag = minLag
        for lag in minLag...maxLag where scores[lag] > scores[bestLag] { bestLag = lag }
        guard scores[bestLag] > 0 else { return nil }

        let baseBPM = 60.0 * fps / Double(bestLag)
        let candidates = [baseBPM, baseBPM * 2, baseBPM / 2]

        var chosenBPM = baseBPM
        var chosenScore: Float = -1
        for candidate in candidates where candidate >= 60 && candidate <= 200 {
            let lag = Int((60.0 * fps / candidate).rounded())
            guard lag >= minLag, lag <= maxLag else { continue }
            var value = scores[lag]
            // Prefer the dance range: this is what fixes 90 vs 180 confusion.
            if preferredRange.contains(candidate) { value *= 1.25 }
            if value > chosenScore {
                chosenScore = value
                chosenBPM = candidate
            }
        }
        guard chosenScore > 0 else { return nil }

        let lag = Int((60.0 * fps / chosenBPM).rounded())
        let refinedLag = refine(scores: scores, lag: lag)
        guard refinedLag > 0 else { return nil }
        let bpm = 60.0 * fps / refinedLag
        guard bpm.isFinite, bpm >= 55, bpm <= 210 else { return nil }

        return Tempo(bpm: (bpm * 10).rounded() / 10, score: chosenScore)
    }

    /// Parabolic interpolation around the autocorrelation peak.
    nonisolated private static func refine(scores: [Float], lag: Int) -> Double {
        guard lag > 1, lag + 1 < scores.count else { return Double(lag) }
        let left = Double(scores[lag - 1])
        let centre = Double(scores[lag])
        let right = Double(scores[lag + 1])
        let denominator = left - 2 * centre + right
        guard abs(denominator) > 1e-9 else { return Double(lag) }
        let delta = 0.5 * (left - right) / denominator
        guard abs(delta) < 1 else { return Double(lag) }
        return Double(lag) + delta
    }

    // MARK: - Beat grid

    nonisolated private static func trackBeats(envelope: [Float], period: Double, fps: Double) -> [TimeInterval] {
        guard period > 2, envelope.count > Int(period * 4) else { return [] }
        let periodInt = max(2, Int(period.rounded()))

        // Phase: the offset whose beat comb collects the most onset energy.
        var bestOffset = 0
        var bestSum: Float = -1
        for offset in 0..<periodInt {
            var sum: Float = 0
            var index = offset
            while index < envelope.count {
                sum += envelope[index]
                index += periodInt
            }
            if sum > bestSum {
                bestSum = sum
                bestOffset = offset
            }
        }

        // Beat-by-beat search inside a tolerance window, with a deviation
        // penalty and a slowly adapting period (drift correction).
        var indices: [Int] = [bestOffset]
        var position = Double(bestOffset)
        var currentPeriod = period
        let tolerance = max(1.0, period * 0.12)

        while position + currentPeriod < Double(envelope.count) {
            let expected = position + currentPeriod
            let lower = max(0, Int((expected - tolerance).rounded()))
            let upper = min(envelope.count - 1, Int((expected + tolerance).rounded()))
            var bestIndex = min(envelope.count - 1, max(0, Int(expected.rounded())))
            var bestScore = -Float.greatestFiniteMagnitude

            if lower <= upper {
                for candidate in lower...upper {
                    let deviation = Float(abs(Double(candidate) - expected) / tolerance)
                    let score = envelope[candidate] - 0.35 * deviation
                    if score > bestScore {
                        bestScore = score
                        bestIndex = candidate
                    }
                }
            }

            let observed = Double(bestIndex) - position
            currentPeriod = min(period * 1.05, max(period * 0.95, currentPeriod * 0.85 + observed * 0.15))
            position = Double(bestIndex)
            indices.append(bestIndex)
        }

        return indices.map { Double($0) / fps }
    }

    nonisolated private static func confidence(
        envelope: [Float],
        beats: [TimeInterval],
        fps: Double,
        autocorrelation: Float
    ) -> Float {
        guard beats.count > 4 else { return 0 }
        let overall = envelope.reduce(0, +) / Float(envelope.count)
        guard overall > 0 else { return 0 }

        var onBeat: Float = 0
        var counted = 0
        for beat in beats {
            let index = Int((beat * fps).rounded())
            guard index >= 0, index < envelope.count else { continue }
            onBeat += envelope[index]
            counted += 1
        }
        guard counted > 0 else { return 0 }

        let ratio = (onBeat / Float(counted)) / overall
        let strength = max(0, min(1, (ratio - 1) / 2))
        let stability = max(0, min(1, autocorrelation * 6))
        return max(0, min(1, 0.6 * strength + 0.4 * stability))
    }

    nonisolated private static func detectDownbeats(
        envelope: [Float],
        beats: [TimeInterval],
        fps: Double
    ) -> [TimeInterval] {
        guard beats.count >= 8 else { return [] }

        var bestPhase = 0
        var bestSum: Float = -1
        for phase in 0..<4 {
            var sum: Float = 0
            var position = phase
            while position < beats.count {
                let index = Int((beats[position] * fps).rounded())
                if index >= 0, index < envelope.count { sum += envelope[index] }
                position += 4
            }
            if sum > bestSum {
                bestSum = sum
                bestPhase = phase
            }
        }

        var result: [TimeInterval] = []
        var position = bestPhase
        while position < beats.count {
            result.append(beats[position])
            position += 4
        }
        return result
    }
}
