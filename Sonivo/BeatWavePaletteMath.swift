import Foundation

/// Pure, bounded palette extraction. No invented hue for black/white artwork.
nonisolated enum BeatWavePaletteMath {
    static func dominantRGB(rgba: [UInt8]) -> [SIMD3<Float>] {
        var buckets: [Int: (weight: Float,sum: SIMD3<Float>)]=[:]
        guard rgba.count%4==0 else { return [] }
        for i in stride(from: 0,to: rgba.count,by: 4) {
            let alpha=Float(rgba[i+3])/255
            guard alpha>0.2 else { continue }
            let rgb=SIMD3(Float(rgba[i]),Float(rgba[i+1]),Float(rgba[i+2]))/(255*alpha)
            let hi=max(rgb.x,max(rgb.y,rgb.z)),lo=min(rgb.x,min(rgb.y,rgb.z))
            let saturation=hi>0 ? (hi-lo)/hi : 0
            let weight=(0.5+saturation)*(hi<0.06 ? 0.05 : 1)*(hi>0.92 && saturation<0.06 ? 0.25 : 1)
            let qx=min(15,max(0,Int(rgb.x*15))),qy=min(15,max(0,Int(rgb.y*15))),qz=min(15,max(0,Int(rgb.z*15)))
            let key=(qx<<8)|(qy<<4)|qz
            var bucket=buckets[key] ?? (weight: Float(0),sum: SIMD3<Float>(repeating: 0))
            bucket.weight+=weight; bucket.sum+=rgb*weight; buckets[key]=bucket
        }
        let ranked=buckets.sorted { $0.value.weight == $1.value.weight ? $0.key<$1.key : $0.value.weight>$1.value.weight }
        var result: [SIMD3<Float>]=[]
        for (_,bucket) in ranked {
            let rgb=bucket.sum/max(0.0001,bucket.weight)
            guard !result.contains(where: { let d=$0-rgb; return d.x*d.x+d.y*d.y+d.z*d.z<0.025 }) else { continue }
            result.append(rgb)
            if result.count==3 { break }
        }
        // Raise only visibility of very dark artwork, keeping its channel ratios/neutrality.
        return result.map { rgb in
            let peak=max(rgb.x,max(rgb.y,rgb.z))
            if peak<0.0001 { return SIMD3<Float>(repeating: 0.18) }
            return rgb*(min(0.92,max(0.18,peak))/peak)
        }
    }
    static func safeHeadroom(potential: Float,current: Float,lowPower: Bool) -> Float {
        guard !lowPower,potential.isFinite,current.isFinite,potential>1 else { return 1 }
        return min(2.5,max(1,min(potential,current)))
    }
}
