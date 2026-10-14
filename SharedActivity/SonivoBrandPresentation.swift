import SwiftUI

struct SonivoBrandGlyph: View {
    var icon = "music"
    var size: CGFloat = 44
    var color: Color = .white
    private var asset: String {
        switch icon {
        case "signature": "SonivoBrandSignature"
        case "wordmark": "SonivoBrandWordmark"
        case "classic": "SonivoBrandClassic"
        default: "SonivoBrandMusic"
        }
    }
    var body: some View {
        Image(asset).resizable().renderingMode(.template).scaledToFit()
            .foregroundStyle(color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SonivoBrandWave: View {
    var color: Color
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array([9.0, 20, 30, 20, 9].enumerated()), id: \.offset) { _, height in
                Capsule().fill(color).frame(width: 4, height: height)
            }
        }.frame(width: 32, height: 32).accessibilityHidden(true)
    }
}

extension Color {
    init(sonivoHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}
