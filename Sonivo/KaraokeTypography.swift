import SwiftUI

/// Approved font study #03: genuine Onest, fixed weight 700, Cyrillic included.
/// Callers retain their existing size/Dynamic Type policy; transport UI stays SF.
@MainActor enum KaraokeTypography {
    static let postScriptName = "Onest-Bold"
    static func font(size: CGFloat) -> Font {
        .custom(postScriptName, fixedSize: size)
    }
}
