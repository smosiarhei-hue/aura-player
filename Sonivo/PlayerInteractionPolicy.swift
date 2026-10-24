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
    static func dominantRGB(rgba: [UInt8]) -> SIMD3<Float>? {
        guard !rgba.isEmpty, rgba.count % 4 == 0 else { return nil }
        var buckets: [Int: (weight: Float, sum: SIMD3<Float>)] = [:]
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Float(rgba[i + 3]) / 255
            guard alpha > 0.2 else { continue }
            let rgb = SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / (255 * alpha)
            let q = [rgb.x, rgb.y, rgb.z].map { min(15, max(0, Int($0 * 15))) }
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
