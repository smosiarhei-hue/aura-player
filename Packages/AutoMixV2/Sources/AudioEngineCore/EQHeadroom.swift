import Foundation

/// Conservative, fixed curve-based headroom; no music-dependent compression.
/// The response is the PCM RBJ model; actual AudioUnit filters can differ.
public enum EQHeadroom {
    private static let frequencies: [Double] = [32,64,125,250,500,1000,2000,4000,8000,16000]
    private static let widths: [Double] = [0.90,0.85,0.75,1,1,1,1,1,1,0.70]

    public static func preamp(gains: [Float], sampleRate: Double) -> Float {
        let values: [Double] = frequencies.indices.map { i in
            guard i < gains.count, gains[i].isFinite else { return 0 }
            return max(-15, min(15, Double(gains[i])))
        }
        guard values.contains(where: { $0 > 0.0001 }) else { return 0 }
        let rate = sampleRate.isFinite && sampleRate >= 8000 ? sampleRate : 48000
        let top = min(20000.0, rate * 0.44)
        // Precalculate coefficients once per UI update, never on the render thread.
        let coefficients = frequencies.indices.compactMap { band -> (Double, Double, Double, Double, Double)? in
            let gain = values[band]
            if abs(gain) < 0.00001 { return nil }
            let w = 2 * Double.pi * min(frequencies[band], rate * 0.44) / rate
            let c = cos(w), sn = sin(w), a = pow(10, gain / 40)
            let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
            if band == 0 || band == frequencies.count - 1 {
                let alpha = sn / 2 * sqrt((a + 1 / a) * (1 / max(widths[band], 0.2) - 1) + 2)
                let beta = 2 * sqrt(a) * alpha
                if band == 0 {
                    b0 = a*((a+1)-(a-1)*c+beta); b1 = 2*a*((a-1)-(a+1)*c); b2 = a*((a+1)-(a-1)*c-beta)
                    a0 = (a+1)+(a-1)*c+beta; a1 = -2*((a-1)+(a+1)*c); a2 = (a+1)+(a-1)*c-beta
                } else {
                    b0 = a*((a+1)+(a-1)*c+beta); b1 = -2*a*((a-1)+(a+1)*c); b2 = a*((a+1)+(a-1)*c-beta)
                    a0 = (a+1)-(a-1)*c+beta; a1 = 2*((a-1)-(a+1)*c); a2 = (a+1)-(a-1)*c-beta
                }
            } else {
                let alpha = sn * sinh(0.34657359027997265 * widths[band] * w / max(sn, 1e-9))
                b0 = 1+alpha*a; b1 = -2*c; b2 = 1-alpha*a
                a0 = 1+alpha/a; a1 = -2*c; a2 = 1-alpha/a
            }
            return (b0/a0,b1/a0,b2/a0,a1/a0,a2/a0)
        }
        var peak = max(0, values[0], values[9])
        for index in 0..<384 {
            let hz = 20 * pow(top / 20, Double(index) / 383)
            let w = 2 * Double.pi * hz / rate
            let c = cos(w), s = sin(w), c2 = cos(2*w), s2 = sin(2*w)
            var db = 0.0
            for (b0,b1,b2,a1,a2) in coefficients {
                let nr = b0+b1*c+b2*c2, ni = -b1*s-b2*s2
                let dr = 1+a1*c+a2*c2, di = -a1*s-a2*s2
                db += 10 * log10(max(nr*nr+ni*ni,1e-30) / max(dr*dr+di*di,1e-30))
            }
            if db.isFinite { peak = max(peak, db) }
        }
        return peak > 0.01 ? Float(-min(48, peak + 0.5)) : 0
    }
}
