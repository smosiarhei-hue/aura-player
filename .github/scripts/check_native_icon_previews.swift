import AppKit
import Foundation

let root=CommandLine.arguments[1]
let names=["SonivoMusic","MusicGraphite","MusicPrism","MusicSapphire","MusicNeon"]
for name in names {
    for rendition in ["Default","Dark"] {
        let url=URL(fileURLWithPath: root).appendingPathComponent(name).appendingPathComponent(rendition+".png")
        guard let bitmap=NSBitmapImageRep(data: try Data(contentsOf: url)) else { fatalError("Unreadable preview: \(name)") }
        func luminance(_ x: Int,_ y: Int) -> Double {
            guard let color=bitmap.colorAt(x: x,y: y)?.usingColorSpace(.sRGB) else { fatalError("Missing pixel") }
            return Double(color.redComponent)*0.2126+Double(color.greenComponent)*0.7152+Double(color.blueComponent)*0.0722
        }
        // Approved logo occupies these fixed coordinates. A background-only image
        // can compile successfully, but cannot pass this foreground visibility check.
        let background=luminance(450,512)
        guard luminance(175,550)-background > 0.12,
              luminance(615,512)-background > 0.12 else {
            fatalError("Foreground covered or invisible: \(name)/\(rendition)")
        }
    }
}
print("All five native music symbols are visible in both renditions")
