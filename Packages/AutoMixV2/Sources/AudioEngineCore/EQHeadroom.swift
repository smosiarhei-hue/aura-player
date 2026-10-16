import Foundation

/// Unity preamp: retain the original level instead of subtracting maximum boost.
/// Actual native peaks are handled by the downstream Apple PeakLimiter.
public enum EQHeadroom {
    public static func preamp(gains: [Float], sampleRate: Double) -> Float { 0 }
}
