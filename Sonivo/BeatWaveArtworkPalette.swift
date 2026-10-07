import SwiftUI
import UIKit

/// Artwork only. Shared cover cache, bounded palette cache; never reads/downloads track audio.
@MainActor
enum BeatWaveArtworkPalette {
    private static var cached: [String: [SIMD3<Float>]]=[:]
    private static var order: [String]=[]

    static func colors(for track: Track) async -> [Color]? {
        let key=track.coverURL ?? "local:\(track.fileName):\(track.artworkSeed)"
        if let rgb=cached[key] { return rgb.map(color) }
        var image=LibraryStore.cachedArtworkImage(for: track)
        if image==nil,let raw=track.coverURL,let url=URL(string: raw),url.scheme=="https" {
            // Give the existing Now Playing cover fetch a chance to populate the shared cache.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return nil }
            image=LibraryStore.cachedArtworkImage(for: track)
            if image==nil {
                guard let (data,response)=try? await URLSession.shared.data(from: url),
                      !Task.isCancelled,data.count<=12_000_000,
                      let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode),
                      let decoded=UIImage(data: data) else { return nil }
                image=decoded
                LibraryStore.cacheArtworkImage(decoded,for: track)
            }
        }
        guard !Task.isCancelled,let image else { return nil }
        let rgb=await Task.detached(priority: .utility) { extract(image) }.value
        guard !Task.isCancelled,!rgb.isEmpty else { return nil }
        cached[key]=rgb; order.removeAll { $0==key }; order.append(key)
        while order.count>32 { cached.removeValue(forKey: order.removeFirst()) }
        return rgb.map(color)
    }
    private static func color(_ rgb: SIMD3<Float>) -> Color {
        Color(.sRGB,red: Double(rgb.x),green: Double(rgb.y),blue: Double(rgb.z),opacity: 1)
    }
    nonisolated private static func extract(_ image: UIImage) -> [SIMD3<Float>] {
        guard let cg=image.cgImage,let space=CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let size=32
        var pixels=[UInt8](repeating: 0,count: size*size*4)
        let valid=pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data: bytes.baseAddress,width: size,height: size,
                bitsPerComponent: 8,bytesPerRow: size*4,space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg,in: CGRect(x: 0,y: 0,width: size,height: size))
            return true
        }
        return valid ? BeatWavePaletteMath.dominantRGB(rgba: pixels) : []
    }
}
