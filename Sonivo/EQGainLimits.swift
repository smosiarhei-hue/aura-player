import Foundation

/// Dense bass centers; upper-frequency controls retain their original positions.
nonisolated enum EQGainLimits {
    static let frequencies: [Float] = [30,40,50,60,70,80,90,100,110,120,130,140,150,160,170,180,190,200,210,220,230,240,250,500,1000,2000,4000,8000,20000]
    static let legacyFrequencies: [Float] = [30,62.5,125,250,500,1000,2000,4000,8000,20000]
    static let maximum: Float = 18
    static func range(at band: Int) -> ClosedRange<Float> { -12...(frequencies.indices.contains(band) && frequencies[band] <= 250 ? maximum : 12) }
    static func clean(_ gain: Float, at band: Int) -> Float {
        guard gain.isFinite else { return 0 }
        let range = range(at:band)
        return max(range.lowerBound,min(range.upperBound,gain))
    }
    static func bandwidth(at band: Int) -> Float {
        guard band > 0, band < frequencies.count - 1 else { return 1 }
        // Neighbor-based octave widths: dense 10-Hz bands must not all be one octave wide.
        guard frequencies[band] <= 250 else { return 1 }
        return max(0.05,min(5,0.5 * log2((frequencies[band] + 10) / (frequencies[band] - 10))))
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
        let expanded = gains.count == legacyFrequencies.count ? resample(gains,from:legacyFrequencies,to:frequencies) : gains
        return frequencies.indices.map { clean(expanded.indices.contains($0) ? expanded[$0] : 0,at:$0) }
    }
}
