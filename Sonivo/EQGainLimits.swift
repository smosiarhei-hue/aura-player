import Foundation

/// Standard 10-band octave graphic EQ (music-player quality).
/// Centers follow the common ISO-ish octave ladder used by consumer players.
/// Ends are shelves; interior bands are one-octave parametrics — even tone,
/// no muddy overlapping bass shelves.
nonisolated enum EQGainLimits {
    /// Working centers (native AU + streamed PCM + DualDeck).
    static let frequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Prior six-band grids (for one-time log-frequency migration).
    static let previousBassTightFrequencies: [Float] = [60, 120, 400, 1000, 2400, 15000]
    static let previousReferenceFrequencies: [Float] = [60, 150, 400, 1000, 2400, 15000]
    static let compact10Frequencies: [Float] = [40, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 15000]
    static let previousCompactFrequencies: [Float] = [30, 60, 120, 250, 500, 1000, 2000, 4000, 8000, 15000]
    static let denseFrequencies: [Float] = [30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180, 190, 200, 210, 220, 230, 240, 250, 500, 1000, 2000, 4000, 8000, 20000]
    static let legacyFrequencies: [Float] = [30, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 20000]
    static let maximum: Float = 15
    static let layoutMarkerKey = "eq.layout.standard10"

    static func range(at band: Int) -> ClosedRange<Float> { -maximum...maximum }
    static func clean(_ gain: Float, at band: Int) -> Float {
        guard gain.isFinite else { return 0 }
        let range = range(at: band)
        return max(range.lowerBound, min(range.upperBound, gain))
    }

    /// Standard graphic widths: steeper shelves, true 1-oct peaking in between.
    static func bandwidth(at band: Int) -> Float {
        let last = frequencies.count - 1
        if band == 0 || band == last { return 0.70 }
        return 1.0
    }

    static func graphX(at band: Int, width: Double) -> Double {
        14 + Double(band) * max(1, width - 28) / Double(max(1, frequencies.count - 1))
    }
    static func graphY(gain: Float, height: Double) -> Double {
        14 + Double(15 - gain) / 30 * max(1, height - 28)
    }
    static func graphHitBand(x: Double, y: Double, width: Double, height: Double, gains: [Float]) -> Int? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 28, height > 28 else { return nil }
        let curve = normalized(gains)
        func distanceSquared(_ band: Int) -> Double {
            let dx = graphX(at: band, width: width) - x
            let dy = graphY(gain: curve[band], height: height) - y
            return dx * dx + dy * dy
        }
        guard let closest = frequencies.indices.min(by: { distanceSquared($0) < distanceSquared($1) }),
              distanceSquared(closest) <= 24 * 24 else { return nil }
        return closest
    }
    static func graphGain(y: Double, height: Double, at band: Int) -> Float {
        let value = Float(15 - (y - 14) / max(1, height - 28) * 30)
        return clean((value * 2).rounded() / 2, at: band)
    }
    static func resample(_ gains: [Float], from source: [Float], to target: [Float]) -> [Float] {
        guard gains.count == source.count, source.count > 1 else { return Array(repeating: 0, count: target.count) }
        let values = gains.map { $0.isFinite ? $0 : 0 }
        return target.map { frequency in
            guard let upper = source.firstIndex(where: { $0 >= frequency }) else { return values.last ?? 0 }
            if source[upper] == frequency { return values[upper] }
            guard upper > 0 else { return values[0] }
            let lower = upper - 1
            let fraction = log(frequency / source[lower]) / log(source[upper] / source[lower])
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }
    static func normalized(_ gains: [Float]) -> [Float] {
        // Ten-value arrays share a count across compact/legacy/standard grids —
        // callers with known centers must resample first. Unmarked six-value
        // imports assume the last shipping bass-tight centers.
        let expanded: [Float]
        if gains.count == frequencies.count {
            expanded = gains
        } else if gains.count == previousBassTightFrequencies.count {
            expanded = resample(gains, from: previousBassTightFrequencies, to: frequencies)
        } else if gains.count == denseFrequencies.count {
            expanded = resample(gains, from: denseFrequencies, to: frequencies)
        } else {
            expanded = gains
        }
        return frequencies.indices.map { clean(expanded.indices.contains($0) ? expanded[$0] : 0, at: $0) }
    }
}

/// Categories select real bands; they never average or overwrite a saved curve.
nonisolated enum EQFrequencyRegion: Int, CaseIterable, Identifiable {
    case low, middle, high
    var id: Int { rawValue }
    var title: String { switch self { case .low: "Низкие"; case .middle: "Средние"; case .high: "Высокие" } }
    var indices: ClosedRange<Int> {
        switch self {
        case .low: 0...2      // 31–125
        case .middle: 3...6   // 250–2k
        case .high: 7...9     // 4k–16k
        }
    }
    var detail: String {
        switch self {
        case .low: "31–125 Гц · саб, удар, низ"
        case .middle: "250 Гц–2 кГц · плотность и голос"
        case .high: "4–16 кГц · яркость и воздух"
        }
    }
    static func containing(_ band: Int) -> Self {
        if band <= 2 { return .low }
        if band <= 6 { return .middle }
        return .high
    }
    static let bandTitles = [
        "Саб", "Бас", "Низ", "Плотность", "Тело",
        "Голос", "Присутствие", "Яркость", "Воздух", "Шёлк"
    ]
}
