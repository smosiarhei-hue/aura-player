import Foundation

/// Intent is measured by real travel, not a velocity prediction or a tap location.
nonisolated enum PlayerInteractionPolicy {
    static func horizontalIntent(x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite && abs(x) >= 10 && abs(x) > abs(y) * 1.6
    }
    static func trackDirection(x: Double, y: Double, width: Double) -> Int? {
        guard horizontalIntent(x: x, y: y), width.isFinite, width > 0,
              abs(x) >= max(80, min(140, width * 0.24)) else { return nil }
        return x < 0 ? 1 : -1
    }
    static func draggedFraction(start: Double, translation: Double, width: Double) -> Double {
        guard start.isFinite, translation.isFinite, width.isFinite, width > 0 else { return 0 }
        return min(1, max(0, start + translation / width))
    }
}

/// Pixel-area ranking, without saturation bonuses that let a small bright accent win.
nonisolated enum PlayerArtworkToneMath {
    /// Choose the higher-contrast monochrome ink against the actual sRGB background.
    static func prefersDarkInk(rgb: SIMD3<Float>?) -> Bool {
        guard let rgb, rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { return false }
        func linear(_ value: Float) -> Double {
            let c = Double(min(1, max(0, value)))
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.x) + 0.7152 * linear(rgb.y) + 0.0722 * linear(rgb.z)
        return luminance > 0.179
    }

    static func dominantRGB(rgba: [UInt8]) -> SIMD3<Float>? {
        guard !rgba.isEmpty, rgba.count % 4 == 0 else { return nil }
        var buckets: [Int: (weight: Float, sum: SIMD3<Float>)] = [:]
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Float(rgba[i + 3]) / 255
            guard alpha > 0.2 else { continue }
            let rgb = SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / (255 * alpha)
            let q = [rgb.x, rgb.y, rgb.z].map { min(7, max(0, Int($0 * 8))) }
            let key = (q[0] << 8) | (q[1] << 4) | q[2]
            var bucket = buckets[key] ?? (0, SIMD3<Float>(repeating: 0))
            bucket.weight += alpha; bucket.sum += rgb * alpha
            buckets[key] = bucket
        }
        let winner = buckets.sorted {
            $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight
        }.first
        guard let bucket = winner?.value else { return nil }
        return bucket.sum / bucket.weight
    }
}
