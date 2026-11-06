import Foundation

/// Puts the next vocal in the same space as the ending instrumental.
/// Phrase-loop tiles the outro bed on the beat grid; optional soft wash is a
/// musical send, not a room node and not system Spatial Audio.
public enum StemMashupGlue {
    public static func shapeInstrumentalBed(
        left: inout [Float],
        right: inout [Float],
        rate: Double,
        loopSec: Double,
        delaySec: Double,
        untilFrame: Int? = nil
    ) {
        guard left.count == right.count, left.count > 8, rate > 8_000 else { return }
        let limit = untilFrame.map { min(max(0, $0), left.count) } ?? left.count
        // Tile a 2/4-bar phrase through the bed so Automix keeps groove under B's vocal.
        if loopSec > 0.25 {
            tilePhraseLoop(&left, &right, rate: rate, loopSec: loopSec, until: limit)
        }
        guard delaySec > 0.05 else { return }
        wash(
            &left, &right,
            rate: rate,
            delaySec: delaySec,
            // Optional lab glue only — PlayerCore Automix usually passes echoDelaySec=0.
            echoWet: 0.10,
            reverbWet: 0.18,
            until: limit
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
            left[i] *= 1.05
            right[i] *= 1.05
        }
        guard delaySec > 0.05 else { return }
        // Nearly dry — any real wash under a live vocal is heard as a third copy.
        wash(
            &left, &right,
            rate: rate,
            delaySec: delaySec,
            echoWet: 0.03,
            reverbWet: 0.08,
            until: until
        )
    }

    /// Crossfade-tile the first `loopSec` of the buffer through `[0, until)`.
    /// Keeps the outro groove repeating while B blooms — DJ seamless-loop bed.
    public static func tilePhraseLoop(
        _ left: inout [Float],
        _ right: inout [Float],
        rate: Double,
        loopSec: Double,
        until: Int
    ) {
        let n = left.count
        let limit = min(max(0, until), n)
        let loopFrames = max(64, Int(loopSec * rate))
        guard loopFrames > 64, loopFrames < limit / 2 else { return }
        let xfade = max(32, min(loopFrames / 8, Int(0.04 * rate)))
        var write = loopFrames
        while write < limit {
            let remain = limit - write
            let copyCount = min(loopFrames, remain)
            for k in 0..<copyCount {
                let src = k
                let dst = write + k
                if k < xfade, write > 0 {
                    let t = Float(k) / Float(xfade)
                    let ease = t * t * (3 - 2 * t)
                    let wa = cos(ease * Float.pi * 0.5)
                    let wb = sin(ease * Float.pi * 0.5)
                    left[dst] = left[dst] * wa + left[src] * wb
                    right[dst] = right[dst] * wa + right[src] * wb
                } else {
                    left[dst] = left[src]
                    right[dst] = right[src]
                }
            }
            // Advance by almost one phrase; overlap provides the crossfade.
            write += max(1, loopFrames - xfade)
        }
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
