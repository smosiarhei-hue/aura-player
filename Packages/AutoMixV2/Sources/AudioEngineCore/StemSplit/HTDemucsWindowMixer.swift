import Foundation

/// Mix a neural stem back toward the dry signal, then bloom to dry at LAND.
public enum HTDemucsWindowMixer {
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
