import Foundation

// MARK: - Energy curve, intro/outro and cue points
//
// RMS energy at 10 windows per second, smoothed, then differentiated to find
// drops and breakdowns. Every candidate is snapped to the nearest downbeat so
// nothing is ever cut on a random sample.

nonisolated struct StructureResult: Sendable {
    var energyCurve: [Float]
    var introEnd: TimeInterval?
    var outroStart: TimeInterval?
    var cuePoints: [CuePoint]

    static let empty = StructureResult(energyCurve: [], introEnd: nil, outroStart: nil, cuePoints: [])
}

nonisolated enum StructureAnalyzer {
    static let windowsPerSecond: Double = 10

    nonisolated static func analyze(features: AudioFeatures, downbeats: [TimeInterval]) -> StructureResult {
        let fps = features.frameRate
        guard fps > 0, features.rms.count > 4 else { return .empty }

        let framesPerWindow = max(1, Int((fps / windowsPerSecond).rounded()))
        var curve: [Float] = []
        var cursor = 0
        while cursor < features.rms.count {
            let end = min(features.rms.count, cursor + framesPerWindow)
            let slice = features.rms[cursor..<end]
            curve.append(slice.reduce(0, +) / Float(slice.count))
            cursor = end
        }
        guard curve.count > 4 else { return .empty }

        // Normalize against a high percentile so one transient does not squash
        // the whole curve.
        let sorted = curve.sorted()
        let referenceIndex = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let reference = sorted[referenceIndex]
        let normalized = reference > 0 ? curve.map { min(1, $0 / reference) } : curve
        let smoothed = movingAverage(normalized, window: 5)
        let median = reference > 0 ? min(1, sorted[sorted.count / 2] / reference) : 0

        func time(_ index: Int) -> TimeInterval { Double(index) / windowsPerSecond }

        func snap(_ value: TimeInterval) -> TimeInterval {
            guard !downbeats.isEmpty else { return value }
            var best = downbeats[0]
            for candidate in downbeats where abs(candidate - value) < abs(best - value) {
                best = candidate
            }
            return abs(best - value) <= 2.5 ? best : value
        }

        // Intro: first stretch of a full second that stays above the active level.
        let activeLevel = max(0.05, median * 0.45)
        let sustain = max(1, Int(windowsPerSecond))
        var introEnd: TimeInterval?
        var index = 0
        while index + sustain < smoothed.count {
            if smoothed[index..<(index + sustain)].allSatisfy({ $0 >= activeLevel }) {
                introEnd = snap(time(index))
                break
            }
            index += 1
        }

        // Outro: where the closing decline crosses 70 % of the median level.
        let outroLevel = max(0.05, median * 0.7)
        var outroIndex = smoothed.count - 1
        while outroIndex > 0, smoothed[outroIndex] < outroLevel { outroIndex -= 1 }
        let outroStart: TimeInterval? = (outroIndex > 0 && outroIndex < smoothed.count - 2)
            ? snap(time(outroIndex))
            : nil

        // Cue points: strongest one-second energy changes, at least 8 s apart.
        let step = max(1, Int(windowsPerSecond))
        var candidates: [(index: Int, delta: Float)] = []
        var position = 0
        while position + step < smoothed.count {
            candidates.append((position, smoothed[position + step] - smoothed[position]))
            position += 1
        }

        var cuePoints: [CuePoint] = []
        let minimumSpacing: TimeInterval = 8
        for candidate in candidates.sorted(by: { abs($0.delta) > abs($1.delta) }) {
            guard abs(candidate.delta) > 0.18 else { break }
            guard cuePoints.count < 12 else { break }
            let candidateTime = snap(time(candidate.index))
            if cuePoints.contains(where: { abs($0.time - candidateTime) < minimumSpacing }) { continue }

            let kind: CuePoint.Kind
            if candidate.delta > 0.30 {
                kind = .preDrop
            } else if candidate.delta > 0 {
                kind = .verseEnd
            } else if candidate.delta < -0.30 {
                kind = .breakdownStart
            } else {
                kind = .chorusEnd
            }

            cuePoints.append(
                CuePoint(
                    time: candidateTime,
                    kind: kind,
                    confidence: min(1, abs(candidate.delta) * 2)
                )
            )
        }
        cuePoints.sort { $0.time < $1.time }

        return StructureResult(
            energyCurve: smoothed,
            introEnd: introEnd,
            outroStart: outroStart,
            cuePoints: cuePoints
        )
    }

    nonisolated private static func movingAverage(_ values: [Float], window: Int) -> [Float] {
        guard window > 1, values.count > window else { return values }
        var result = [Float](repeating: 0, count: values.count)
        var sum: Float = 0
        var queue: [Float] = []
        for index in values.indices {
            queue.append(values[index])
            sum += values[index]
            if queue.count > window { sum -= queue.removeFirst() }
            result[index] = sum / Float(queue.count)
        }
        return result
    }
}
