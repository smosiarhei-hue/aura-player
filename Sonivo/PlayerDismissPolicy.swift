/// Direction and scroll-boundary policy shared by the header and cover dismissal gestures.
/// Audio controls and lyrics scroll content are deliberately not dismissal surfaces.
nonisolated enum PlayerDismissPolicy {
    static func canBegin(x: Double, y: Double, requiresScrollTop: Bool, isAtTop: Bool) -> Bool {
        guard x.isFinite, y.isFinite, !requiresScrollTop || isAtTop else { return false }
        return y > 0 && y > abs(x) * 1.25
    }

    static func shouldClose(x: Double, y: Double, predictedY: Double) -> Bool {
        guard canBegin(x: x, y: y, requiresScrollTop: false, isAtTop: true),
              predictedY.isFinite else { return false }
        return y > 110 || predictedY > 240
    }
}
