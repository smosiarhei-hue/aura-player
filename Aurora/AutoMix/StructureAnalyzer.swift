import Foundation

// MARK: - Energy curve, structure, vocal and silence mapping
//
// RMS energy at 10 windows per second, smoothed, then differentiated to find
// drops and breakdowns. Every candidate is snapped to the nearest downbeat so
// nothing is ever cut on a random sample. The per-frame vocal-band ratio from
// AutoMixDSP becomes a smoothed vocal-activity curve; sustained stretches of
// it mark vocal and instrumental regions, and the energy curve is segmented
// into intro / verse / chorus / drop / breakdown / outro sections that the
// transition planner uses for phrase-aware cue points.

nonisolated struct StructureResult: Sendable {
    var energyCurve: [Float]
    var vocalCurve: [Float]
    var introEnd: TimeInterval?
    var outroStart: TimeInterval?
    var cuePoints: [CuePoint]
    var sections: [MusicSection]
    var silenceRegions: [TimeRange]
    var vocalRegions: [TimeRange]
    var instrumentalRegions: [TimeRange]
    var buildUps: [TimeRange]

    static let empty = StructureResult(
        energyCurve: [],
        vocalCurve: [],
        introEnd: nil,
        outroStart: nil,
        cuePoints: [],
        sections: [],
        silenceRegions: [],
        vocalRegions: [],
        instrumentalRegions: [],
        buildUps: []
    )
}

nonisolated enum StructureAnalyzer {
    static let windowsPerSecond: Double = 10

    nonisolated static func analyze(features: AudioFeatures, downbeats: [TimeInterval]) -> StructureResult {
        let fps = features.frameRate
        guard fps > 0, features.rms.count > 4 else { return .empty }

        let framesPerWindow = max(1, Int((fps / windowsPerSecond).rounded()))

        func windowed(_ source: [Float]) -> [Float] {
            var curve: [Float] = []
            curve.reserveCapacity(source.count / framesPerWindow + 1)
            var cursor = 0
            while cursor < source.count {
                let end = min(source.count, cursor + framesPerWindow)
                let slice = source[cursor..<end]
                curve.append(slice.reduce(0, +) / Float(slice.count))
                cursor = end
            }
            return curve
        }

        let energy = windowed(features.rms)
        guard energy.count > 4 else { return .empty }
        let vocal = windowed(features.vocalRatio.count == features.rms.count ? features.vocalRatio : [])

        // Normalize against a high percentile so one transient does not squash
        // the whole curve.
        let sorted = energy.sorted()
        let referenceIndex = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let reference = sorted[referenceIndex]
        let normalized = reference > 0 ? energy.map { min(1, $0 / reference) } : energy
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

        let silenceRegions = detectSilenceRegions(smoothed)
        let (vocalRegions, instrumentalRegions) = detectVocalRegions(vocal)
        let buildUps = detectBuildUps(smoothed, cuePoints: cuePoints)
        let sections = detectSections(
            smoothed,
            introEnd: introEnd ?? time(sustain),
            outroStart: outroStart ?? time(max(0, smoothed.count - sustain * 2)),
            cuePoints: cuePoints
        )

        return StructureResult(
            energyCurve: smoothed,
            vocalCurve: vocal,
            introEnd: introEnd,
            outroStart: outroStart,
            cuePoints: cuePoints,
            sections: sections,
            silenceRegions: silenceRegions,
            vocalRegions: vocalRegions,
            instrumentalRegions: instrumentalRegions,
            buildUps: buildUps
        )
    }

    // MARK: - Silence

    /// Sustained windows under 2 % of the reference level, merged into regions
    /// of at least 1.2 seconds.
    nonisolated private static func detectSilenceRegions(_ curve: [Float]) -> [TimeRange] {
        let threshold: Float = 0.02
        var regions: [TimeRange] = []
        var start: Int? = nil

        for index in curve.indices {
            if curve[index] < threshold {
                if start == nil { start = index }
            } else if let from = start {
                appendRegion(&regions, from: from, to: index, minimum: 1.2)
                start = nil
            }
        }
        if let from = start {
            appendRegion(&regions, from: from, to: curve.count, minimum: 1.2)
        }
        return regions
    }

    nonisolated private static func appendRegion(_ regions: inout [TimeRange], from: Int, to: Int, minimum: TimeInterval) {
        let start = Double(from) / windowsPerSecond
        let end = Double(to) / windowsPerSecond
        guard end - start >= minimum else { return }
        if let last = regions.last, last.end >= start - 0.5 {
            regions[regions.count - 1] = TimeRange(start: last.start, end: max(last.end, end))
        } else {
            regions.append(TimeRange(start: start, end: end))
        }
    }

    // MARK: - Vocal activity

    /// Sustained stretches of high vocal-band ratio become vocal regions;
    /// long low-ratio stretches that still carry music become instrumental
    /// regions - exactly what the planner needs to avoid vocal collisions.
    nonisolated private static func detectVocalRegions(_ vocal: [Float]) -> (vocal: [TimeRange], instrumental: [TimeRange]) {
        guard vocal.count > Int(windowsPerSecond * 8) else { return ([], []) }
        let smoothed = movingAverage(vocal, window: Int(windowsPerSecond))
        let sorted = smoothed.sorted()
        let low = sorted[Int(Double(sorted.count) * 0.35)]
        let high = sorted[Int(Double(sorted.count) * 0.72)]
        guard high > low else { return ([], []) }

        var vocalRegions: [TimeRange] = []
        var instrumentalRegions: [TimeRange] = []
        var cursor = 0

        while cursor < smoothed.count {
            let isVocal = smoothed[cursor] >= high
            var end = cursor
            while end < smoothed.count, (smoothed[end] >= high) == isVocal { end += 1 }

            let start = Double(cursor) / windowsPerSecond
            let stop = Double(end) / windowsPerSecond
            if isVocal, stop - start >= 5 {
                vocalRegions.append(TimeRange(start: start, end: stop))
            } else if !isVocal, smoothed[cursor] <= low, stop - start >= 6 {
                instrumentalRegions.append(TimeRange(start: start, end: stop))
            }
            cursor = end
        }
        return (vocalRegions, instrumentalRegions)
    }

    // MARK: - Build-ups

    /// A rising energy run of at least 4 s that ends right before a pre-drop
    /// cue point.
    nonisolated private static func detectBuildUps(_ curve: [Float], cuePoints: [CuePoint]) -> [TimeRange] {
        var result: [TimeRange] = []
        for cue in cuePoints where cue.kind == .preDrop {
            let dropIndex = Int(cue.time * windowsPerSecond)
            guard dropIndex > Int(windowsPerSecond * 8), dropIndex < curve.count else { continue }

            let riseStart = max(0, dropIndex - Int(windowsPerSecond * 12))
            var window: [Float] = Array(curve[riseStart..<dropIndex])
            guard window.count >= Int(windowsPerSecond * 4) else { continue }

            // Walk backwards from the drop while the curve keeps rising overall.
            var start = window.count - 1
            while start > 0 {
                let earlier = window[max(0, start - Int(windowsPerSecond))]
                let later = window[start]
                if later < earlier - 0.02 { break }
                start -= 1
            }
            window.removeFirst(start)

            let rise = (window.last ?? 0) - (window.first ?? 0)
            guard rise >= 0.12 else { continue }

            let startTime = Double(riseStart + start) / windowsPerSecond
            if startTime < cue.time - 3 {
                result.append(TimeRange(start: startTime, end: cue.time))
            }
        }
        return result
    }

    // MARK: - Sections

    /// Energy-percentile classification of ~8 second windows, merged between
    /// neighbours of the same type. Downbeat snapping already happened at the
    /// cue-point level; section boundaries stay on second granularity.
    nonisolated private static func detectSections(
        _ curve: [Float],
        introEnd: TimeInterval,
        outroStart: TimeInterval,
        cuePoints: [CuePoint]
    ) -> [MusicSection] {
        guard !curve.isEmpty else { return [] }
        let sorted = curve.sorted()
        func percentile(_ fraction: Double) -> Float {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        let p25 = percentile(0.25)
        let p75 = percentile(0.75)
        let p92 = percentile(0.92)

        let windowSize = max(2, Int(windowsPerSecond * 8))
        var result: [MusicSection] = []

        var cursor = 0
        while cursor < curve.count {
            let end = min(curve.count, cursor + windowSize)
            let slice = curve[cursor..<end]
            let mean = Double(slice.reduce(0, +) / Float(slice.count))
            let start = Double(cursor) / windowsPerSecond
            let stop = Double(end) / windowsPerSecond

            let type: SectionType
            if stop <= introEnd + 1 {
                type = .intro
            } else if start >= outroStart - 1 {
                type = .outro
            } else if mean >= Double(p92) {
                type = .drop
            } else if mean >= Double(p75) {
                type = .chorus
            } else if mean <= Double(p25) {
                type = .breakdown
            } else {
                type = .verse
            }

            if let last = result.last, last.type == type {
                result[result.count - 1] = MusicSection(
                    start: last.start,
                    end: stop,
                    type: last.type,
                    energy: (last.energy + mean) / 2
                )
            } else {
                result.append(MusicSection(start: start, end: stop, type: type, energy: mean))
            }
            cursor = end
        }

        return result
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
