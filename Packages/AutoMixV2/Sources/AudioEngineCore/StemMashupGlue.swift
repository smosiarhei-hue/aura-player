import Foundation

/// Puts the next vocal in the same space as the ending instrumental.
/// The bed plays forward. A light tempo echo and a short plate sit on both
/// stems, lighter on the vocal so the words stay in front.
/// Repeating the outro as a phrase loop sounded like the next song stuttering.
/// This is a musical send, not a room node and not system Spatial Audio.
public enum StemMashupGlue {
    public static func shapeInstrumentalBed(
        left: inout [Float],
        right: inout [Float],
        rate: Double,
        loopSec: Double,
        delaySec: Double
    ) {
        guard left.count == right.count, left.count > 8, rate > 8_000 else { return }
        _ = loopSec
        wash(
            &left, &right,
            rate: rate,
            delaySec: delaySec,
            echoWet: 0.14,
            reverbWet: 0.28,
            until: left.count
        )
    }

    /// Frames at LAND and after stay dry. That stretch is the next song.
    public static func shapeIncomingVocal(
        left: inout [Float],
        right: inout [Float],
        rate: Double,
        delaySec: Double,
        untilFrame: Int
    ) {
        guard left.count == right.count, rate > 8_000 else { return }
        let until = min(max(0, untilFrame), left.count)
        guard until > 8 else { return }
        for i in 0..<until {
            left[i] *= 1.12
            right[i] *= 1.12
        }
        wash(
            &left, &right,
            rate: rate,
            delaySec: delaySec,
            echoWet: 0.06,
            reverbWet: 0.20,
            until: until
        )
    }

    private static func wash(
        _ left: inout [Float],
        _ right: inout [Float],
        rate: Double,
        delaySec: Double,
        echoWet: Float,
        reverbWet: Float,
        until: Int
    ) {
        let n = left.count
        guard n > 8, echoWet > 0.01 || reverbWet > 0.01 else { return }
        let delayFrames = max(1, Int(min(0.75, max(0.08, delaySec)) * rate))
        var echoL = [Float](repeating: 0, count: delayFrames)
        var echoR = [Float](repeating: 0, count: delayFrames)
        var echoPos = 0
        let combMsL: [Double] = [23, 31, 41]
        let combMsR: [Double] = [29, 37, 47]
        let combL = combMsL.map { max(1, Int($0 * rate / 1000)) }
        let combR = combMsR.map { max(1, Int($0 * rate / 1000)) }
        var stateL = combL.map { [Float](repeating: 0, count: $0) }
        var stateR = combR.map { [Float](repeating: 0, count: $0) }
        var posL = [Int](repeating: 0, count: combL.count)
        var posR = [Int](repeating: 0, count: combR.count)
        let echoFeedback: Float = 0.16
        let combFeedback: Float = 0.28
        let tail = Int(0.55 * rate)
        let wetUntil = min(max(0, until), n)

        for i in 0..<n {
            let dryL = left[i]
            let dryR = right[i]
            let delayedL = echoL[echoPos]
            let delayedR = echoR[echoPos]
            var writeL = dryL + delayedL * echoFeedback
            var writeR = dryR + delayedR * echoFeedback
            if !writeL.isFinite { writeL = 0 }
            if !writeR.isFinite { writeR = 0 }
            echoL[echoPos] = writeL
            echoR[echoPos] = writeR
            echoPos = echoPos + 1 == delayFrames ? 0 : echoPos + 1

            var plateL: Float = 0
            var plateR: Float = 0
            for c in 0..<combL.count {
                let y = stateL[c][posL[c]]
                var feed = dryL + delayedL * 0.3 + y * combFeedback
                if !feed.isFinite { feed = 0 }
                stateL[c][posL[c]] = feed
                posL[c] = posL[c] + 1 == combL[c] ? 0 : posL[c] + 1
                plateL += y
            }
            for c in 0..<combR.count {
                let y = stateR[c][posR[c]]
                var feed = dryR + delayedR * 0.3 + y * combFeedback
                if !feed.isFinite { feed = 0 }
                stateR[c][posR[c]] = feed
                posR[c] = posR[c] + 1 == combR[c] ? 0 : posR[c] + 1
                plateR += y
            }
            plateL /= Float(combL.count)
            plateR /= Float(combR.count)

            if i >= wetUntil + tail { continue }

            var addL = delayedL * echoWet * 0.62 + plateL * reverbWet * 0.58
            var addR = delayedR * echoWet * 0.62 + plateR * reverbWet * 0.58
            if i >= wetUntil {
                let t = Float(i - wetUntil) / Float(max(1, tail))
                let gate = cos(min(1, max(0, t)) * Float.pi * 0.5)
                addL *= gate
                addR *= gate
            }
            left[i] = soften(dryL + addL)
            right[i] = soften(dryR + addR)
        }
    }

    private static func soften(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        let magnitude = abs(sample)
        if magnitude <= 0.94 { return sample }
        let sign: Float = sample < 0 ? -1 : 1
        let over = magnitude - 0.94
        return sign * (0.94 + over / (1 + over * 2.2))
    }
}
