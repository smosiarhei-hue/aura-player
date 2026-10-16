import Foundation

/// Control-queue estimate of the same one-octave RBJ curve used by streamed PCM.
/// AVAudioUnitEQ is not specified to be bit-identical to RBJ; native peak limiting
/// remains necessary. Never call this response scan from an audio render callback.
public enum EQHeadroom {
    public static func preamp(gains: [Float], sampleRate: Double) -> Float {
        let frequencies: [Double] = [30,60,120,250,500,1000,2000,4000,8000,15000]
        let rate = sampleRate.isFinite && sampleRate >= 8000 ? sampleRate : 48000
        let values = frequencies.indices.map { i -> Double in
            let g = i < gains.count && gains[i].isFinite ? Double(gains[i]) : 0
            return max(-12, min(i < 4 ? 18 : 12, g))
        }
        guard values.contains(where: { $0 > 0 }) else { return 0 }
        let filters = frequencies.indices.map { i -> [Double] in
            let g = values[i]
            if abs(g) < 0.00001 { return [1,0,0,0,0] }
            let w = 2 * Double.pi * min(frequencies[i], rate * 0.44) / rate
            let c = cos(w), sn = sin(w), a = pow(10, g / 40)
            let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
            if i == 0 || i == 9 {
                let beta = 2 * sqrt(a) * sn / sqrt(2)
                if i == 0 {
                    b0=a*((a+1)-(a-1)*c+beta); b1=2*a*((a-1)-(a+1)*c); b2=a*((a+1)-(a-1)*c-beta)
                    a0=(a+1)+(a-1)*c+beta; a1 = -2*((a-1)+(a+1)*c); a2=(a+1)+(a-1)*c-beta
                } else {
                    b0=a*((a+1)+(a-1)*c+beta); b1 = -2*a*((a-1)+(a+1)*c); b2=a*((a+1)+(a-1)*c-beta)
                    a0=(a+1)-(a-1)*c+beta; a1=2*((a-1)-(a+1)*c); a2=(a+1)-(a-1)*c-beta
                }
            } else {
                let alpha = sn * sinh(log(2) / 2 * w / max(sn, 1e-9))
                b0=1+alpha*a; b1 = -2*c; b2=1-alpha*a
                a0=1+alpha/a; a1 = -2*c; a2=1-alpha/a
            }
            return [b0/a0,b1/a0,b2/a0,a1/a0,a2/a0]
        }
        var peak = 0.0
        for i in 0...1025 {
            let hz = i == 0 ? 0 : (i == 1025 ? rate * 0.5 : 10 * pow(rate * 0.05, Double(i-1)/1023))
            let w = 2 * Double.pi * hz / rate
            let c = cos(w), sn = sin(w), c2 = cos(2*w), s2 = sin(2*w)
            var db = 0.0
            for k in filters {
                let nr=k[0]+k[1]*c+k[2]*c2, ni = -k[1]*sn-k[2]*s2
                let dr=1+k[3]*c+k[4]*c2, di = -k[3]*sn-k[4]*s2
                db += 10 * log10(max(1e-30, (nr*nr+ni*ni) / max(1e-30, dr*dr+di*di)))
            }
            peak = max(peak, db)
        }
        return Float(-max(0, min(48, peak+1)))
    }
}
