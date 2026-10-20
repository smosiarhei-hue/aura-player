import SwiftUI

/// Animate only the viewport, never the clock, source selection or word onset.
@MainActor enum LyricsFocusMotion {
    static let duration: Double = 0.24
    static func scroll(reduceMotion: Bool, action: () -> Void) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { action() }
        } else {
            withAnimation(.smooth(duration: duration, extraBounce: 0)) { action() }
        }
    }
}
