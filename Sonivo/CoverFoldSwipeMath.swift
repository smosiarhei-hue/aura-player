import CoreGraphics
import Foundation
import SwiftUI

/// Folding-cards carousel math (Basit / Bencho reference):
/// separate floating plates — center flat/large, sides mesh-warp + scale down.
/// Heavy `rotation3DEffect` alone looks like cubes; warp carries the fold look.
/// `progress` is finger travel / cover width (positive = reveal previous from the left).
nonisolated enum CoverFoldSwipeMath {
    /// Tiny rigid tilt under the Metal warp (depth cue only — not the fold).
    static let maxFoldDegrees: Double = 12
    static let perspective: CGFloat = 0.62
    /// Side plates ~0.74× like the reference peeks.
    static let sideScale: CGFloat = 0.74
    /// Soft rubber past one full slot so a throw still feels physical.
    static let progressLimit: CGFloat = 1.18
    /// Keep a clear gap between plates (reference never hinges them together).
    static let clusterFactor: CGFloat = 0.92
    /// Corner radius relative to cover side (continuous cards, not hard cubes).
    static let cornerRadiusFactor: CGFloat = 0.045

    static func progress(dragX: CGFloat, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, dragX.isFinite else { return 0 }
        return max(-progressLimit, min(progressLimit, dragX / width))
    }

    /// Signed distance used by the Metal warp (`slot + progress`).
    static func warpAmount(slot: Int, progress: CGFloat) -> Float {
        Float(CGFloat(slot) + progress)
    }

    /// Horizontal travel of a slot (−1 previous, 0 current, +1 next).
    static func slotOffset(slot: Int, progress: CGFloat, width: CGFloat) -> CGFloat {
        let t = CGFloat(slot) + progress
        return t * width * clusterFactor
    }

    /// Distance from the focus plane; 0 = fully centered.
    static func centeredness(slot: Int, progress: CGFloat) -> CGFloat {
        abs(CGFloat(slot) + progress)
    }

    /// Light Y tilt under the mesh warp (outer edge away) — keep mild.
    static func foldDegrees(slot: Int, progress: CGFloat) -> Double {
        let t = Double(slot) + Double(progress)
        return -t * maxFoldDegrees
    }

    static func scale(slot: Int, progress: CGFloat) -> CGFloat {
        let t = min(1, centeredness(slot: slot, progress: progress))
        // Ease into the side scale so mid-swipe still reads as a fold, not a pop.
        let eased = t * t * (3 - 2 * t)
        return 1 - eased * (1 - sideScale)
    }

    /// Keep opacity high until the plate is nearly off — reference barely fades.
    static func opacity(slot: Int, progress: CGFloat) -> Double {
        let t = Double(centeredness(slot: slot, progress: progress))
        if t <= 1.12 { return 1 }
        return max(0, 1 - (t - 1.12) / 0.28)
    }

    static func zIndex(slot: Int, progress: CGFloat) -> Double {
        2 - Double(centeredness(slot: slot, progress: progress))
    }

    /// Whether a side slot is close enough to draw (skip far off-screen plates).
    static func isVisible(slot: Int, progress: CGFloat) -> Bool {
        centeredness(slot: slot, progress: progress) < 1.35
    }

    /// Resting peeks stay subtle; mid-swipe neighbors fully engage.
    static func shouldDrawNeighbor(slot: Int, progress: CGFloat) -> Bool {
        if slot == 0 { return true }
        // Always allow a thin peek so the carousel reads as multi-card.
        return isVisible(slot: slot, progress: progress)
    }
}

/// Soft settle — critically / lightly underdamped, no aggressive bounce.
@MainActor enum CoverFoldSwipeMotion {
    static var commitAnimation: Animation {
        .spring(response: 0.45, dampingFraction: 0.85, blendDuration: 0)
    }
    static var cancelAnimation: Animation {
        .spring(response: 0.40, dampingFraction: 0.88, blendDuration: 0)
    }
    /// One full slot after commit so the fold finishes before the track swap.
    static let commitHoldMilliseconds: UInt64 = 420
}
