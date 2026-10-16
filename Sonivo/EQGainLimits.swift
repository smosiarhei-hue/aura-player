import Foundation

/// Compact octave-style controls: one screen, real centers from 30 Hz to 15 kHz.
nonisolated enum EQGainLimits {
    static let frequencies: [Float] = [30,60,120,250,500,1000,2000,4000,8000,15000]
    static let denseFrequencies: [Float] = [30,40,50,60,70,80,90,100,110,120,130,140,150,160,170,180,190,200,210,220,230,240,250,500,1000,2000,4000,8000,20000]
    static let legacyFrequencies: [Float] = [30,62.5,125,250,500,1000,2000,4000,8000,20000]
    static let maximum: Float = 18
    static func range(at band: Int) -> ClosedRange<Float> { -12...(frequencies.indices.contains(band) && frequencies[band] <= 250 ? maximum : 12) }
    static func clean(_ gain: Float, at band: Int) -> Float {
        guard gain.isFinite else { return 0 }
        let range = range(at:band)
        return max(range.lowerBound,min(range.upperBound,gain))
    }
    static func bandwidth(at band: Int) -> Float {
        // Octave-style spacing: local AU and streamed PCM use the same width.
        return 1
    }
    static func graphX(at band: Int, width: Double) -> Double {
        14 + Double(band) * max(1, width - 28) / Double(frequencies.count - 1)
    }
    static func graphY(gain: Float, height: Double) -> Double {
        14 + Double(18 - gain) / 30 * max(1, height - 28)
    }
    static func graphGain(y: Double, height: Double, at band: Int) -> Float {
        let value = Float(18 - (y - 14) / max(1, height - 28) * 30)
        return clean((value * 2).rounded() / 2, at: band)
    }
    static func resample(_ gains: [Float], from source: [Float], to target: [Float]) -> [Float] {
        guard gains.count == source.count, source.count > 1 else { return Array(repeating:0,count:target.count) }
        let values = gains.map { $0.isFinite ? $0 : 0 }
        return target.map { frequency in
            guard let upper = source.firstIndex(where: { $0 >= frequency }) else { return values.last ?? 0 }
            guard upper > 0 else { return values[0] }
            let lower = upper - 1
            let fraction = log(frequency / source[lower]) / log(source[upper] / source[lower])
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }
    static func normalized(_ gains: [Float]) -> [Float] {
        let expanded = gains.count == denseFrequencies.count ? resample(gains,from:denseFrequencies,to:frequencies) : gains
        return frequencies.indices.map { clean(expanded.indices.contains($0) ? expanded[$0] : 0,at:$0) }
    }
}

/// Categories select real bands; they never average or overwrite a saved curve.
nonisolated enum EQFrequencyRegion: Int, CaseIterable, Identifiable {
    case low, middle, high
    var id: Int { rawValue }
    var title: String { switch self { case .low: "Низкие"; case .middle: "Средние"; case .high: "Высокие" } }
    var indices: ClosedRange<Int> { switch self { case .low: 0...3; case .middle: 4...6; case .high: 7...9 } }
    var detail: String { switch self {
        case .low: "30–250 Гц · глубина, удар и тепло"
        case .middle: "500 Гц–2 кГц · инструменты, голос и разборчивость"
        case .high: "4–15 кГц · атака, яркость и воздух"
    } }
    static func containing(_ band: Int) -> Self { band < 4 ? .low : (band < 7 ? .middle : .high) }
    static let bandTitles = ["Саб-бас", "Глубина", "Удар", "Тепло", "Плотность", "Голос", "Разборчивость", "Атака", "Яркость", "Воздух"]
}
