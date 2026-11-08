import Foundation

/// Mix a neural stem back toward the dry signal, then bloom to dry at LAND.
public enum HTDemucsWindowMixer {
    /// Keep B's vocal prominent while allowing some of its original backing
    /// through. A convex dry/stem blend avoids summing two correlated versions.
    public static let automixIncomingVocalAmount: Float = 0.5

    /// Match the AutoMix deck's supported locked-rate range when positioning
    /// the stem-to-dry bloom. This is not an audio-clock synchronisation.
    public static func automixBakeRate(_ plannedRate: Double) -> Double {
        guard plannedRate.isFinite else { return 1 }
        return min(1.08, max(0.92, plannedRate))
    }

    /// A bake contains source-file samples, not samples at the deck's output
    /// speed. Convert the planned wall-clock bars into source-file seconds so
    /// the loop has the intended duration after TimePitch changes deck A's rate.
    public static func sourceLoopSeconds(bars: Int, targetBPM: Double, rateA: Double) -> Double {
        // Rates reach this function through Float; allow its rounding at ±8%.
        guard bars > 0, bars <= 32, targetBPM.isFinite, targetBPM > 30,
              rateA.isFinite, rateA >= 0.9199, rateA <= 1.0801 else { return 0 }
        return Double(bars) * 240.0 / targetBPM * rateA
    }

    public static func render(
        dryL: [Float],
        dryR: [Float],
        stemL: [Float],
        stemR: [Float],
        amount: Float,
        untilFrame: Int?,
        fadeFrames: Int
    ) -> (left: [Float], right: [Float]) {
        let n = min(dryL.count, dryR.count, stemL.count, stemR.count)
        let wet = min(1, max(0, amount))
        let dryMix = 1 - wet
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        for i in 0..<n {
            left[i] = dryL[i] * dryMix + stemL[i] * wet
            right[i] = dryR[i] * dryMix + stemR[i] * wet
        }
        guard let until = untilFrame, until > 0, until < n else {
            return (left, right)
        }
        let fade = max(1, fadeFrames)
        let fadeStart = until > fade ? until - fade : 0
        for i in 0..<n {
            if i >= until {
                left[i] = dryL[i]
                right[i] = dryR[i]
            } else if i >= fadeStart {
                let t = Float(i - fadeStart) / Float(fade)
                let s = t * t * (3 - 2 * t)
                let wa = 1 - s
                let wb = s
                left[i] = left[i] * wa + dryL[i] * wb
                right[i] = right[i] * wa + dryR[i] * wb
            }
        }
        return (left, right)
    }
}
