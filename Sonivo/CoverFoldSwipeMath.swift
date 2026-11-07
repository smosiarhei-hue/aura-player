import CoreGraphics
import Foundation
import SwiftUI

/// Folding-cards carousel math (Basit / Bencho reference):
/// center slot is flat; side slots fold on Y and scale down as they leave the middle.
/// `progress` is finger travel / cover width (positive = reveal previous from the left).
nonisolated enum CoverFoldSwipeMath {
    static let maxFoldDegrees: Double = 52
    static let perspective: CGFloat = 0.55
    static let sideScale: CGFloat = 0.90
    /// Soft rubber past one full slot so a throw still feels physical.
    static let progressLimit: CGFloat = 1.18

    static func progress(dragX: CGFloat, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, dragX.isFinite else { return 0 }
        return max(-progressLimit, min(progressLimit, dragX / width))
    }

    /// Horizontal travel of a slot (−1 previous, 0 current, +1 next).
    static func slotOffset(slot: Int, progress: CGFloat, width: CGFloat) -> CGFloat {
        (CGFloat(slot) + progress) * width
    }

    /// Distance from the focus plane; 0 = fully centered.
    static func centeredness(slot: Int, progress: CGFloat) -> CGFloat {
        abs(CGFloat(slot) + progress)
    }

    /// Y-axis fold: outer edge bends away; center opens flat.
    static func foldDegrees(slot: Int, progress: CGFloat) -> Double {
        let t = Double(slot) + Double(progress)
        return -t * maxFoldDegrees
    }

    static func scale(slot: Int, progress: CGFloat) -> CGFloat {
        let t = min(1, centeredness(slot: slot, progress: progress))
        return 1 - t * (1 - sideScale)
    }

    static func opacity(slot: Int, progress: CGFloat) -> Double {
        let t = Double(centeredness(slot: slot, progress: progress))
        if t <= 1.05 { return 1 }
        return max(0, 1 - (t - 1.05) / 0.35)
    }

    static func zIndex(slot: Int, progress: CGFloat) -> Double {
        2 - Double(centeredness(slot: slot, progress: progress))
    }

    /// Whether a side slot is close enough to draw (skip far off-screen plates).
    static func isVisible(slot: Int, progress: CGFloat) -> Bool {
        centeredness(slot: slot, progress: progress) < 1.35
    }
}

/// Compositor springs for the fold settle — ProMotion-friendly smooth curves.
@MainActor enum CoverFoldSwipeMotion {
    static var commitAnimation: Animation {
        .smooth(duration: 0.42, extraBounce: 0.04)
    }
    static var cancelAnimation: Animation {
        .smooth(duration: 0.36, extraBounce: 0.06)
    }
    /// One full slot after commit so the fold finishes before the track swap.
    static let commitHoldMilliseconds: UInt64 = 400
}
