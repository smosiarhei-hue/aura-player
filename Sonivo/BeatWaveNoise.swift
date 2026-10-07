import Foundation

/// Archive hash/Hermite noise. RGB packs normalized 3/2/1 octave fields once, never per frame.
nonisolated enum BeatWaveNoise {
    static let side=512
    static func base() -> [UInt8] {
        var permutation=[Float](repeating: 0,count: 16384)
        for i in permutation.indices {
            var a=(UInt32(0x27d4eb2d)^UInt32(i)) &* 0x165667b1
            a ^= a >> 15; a = a &* 0x2545f491
            permutation[i]=Float(Double(a ^ (a >> 13))/4294967296)
        }
        func at(_ x: Int,_ y: Int) -> Float { permutation[(y&127)*128+(x&127)] }
        var result=[UInt8](repeating: 0,count: side*side)
        for y in 0..<side {
            let ny=Float(y)/4,iy=Int(ny),fy=ny-Float(iy),sy=fy*fy*(3-2*fy)
            for x in 0..<side {
                let nx=Float(x)/4,ix=Int(nx),fx=nx-Float(ix),sx=fx*fx*(3-2*fx)
                let a=at(ix,iy)+(at(ix+1,iy)-at(ix,iy))*sx
                let b=at(ix,iy+1)+(at(ix+1,iy+1)-at(ix,iy+1))*sx
                result[y*side+x]=UInt8(max(0,min(255,Int(((a+(b-a)*sy)*255).rounded()))))
            }
        }
        return result
    }
    static func sample(_ values: [UInt8],x: Float,y: Float) -> Float {
        let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-Float(ix),fy=y-Float(iy)
        func at(_ xx: Int,_ yy: Int) -> Float { Float(values[(yy&511)*side+(xx&511)])/255 }
        let a=at(ix,iy)+(at(ix+1,iy)-at(ix,iy))*fx
        let b=at(ix,iy+1)+(at(ix+1,iy+1)-at(ix,iy+1))*fx
        return a+(b-a)*fy
    }
    static func rgba() -> [UInt8] {
        let values=base()
        var result=[UInt8](repeating: 255,count: side*side*4)
        for y in 0..<side { for x in 0..<side {
            let a=Float(values[y*side+x])/255
            // Texture coordinates include texel centres, exactly as the archive's linear sampler.
            let b=sample(values,x: Float(x*2)+0.5,y: Float(y*2)+0.5)
            let c=sample(values,x: Float(x*4)+1.5,y: Float(y*4)+1.5)
            let index=(y*side+x)*4
            result[index]=UInt8(((a+b*0.5+c*0.25)/1.75*255).rounded())
            result[index+1]=UInt8(((a+b*0.5)/1.5*255).rounded())
            result[index+2]=values[y*side+x]
        } }
        return result
    }
}
