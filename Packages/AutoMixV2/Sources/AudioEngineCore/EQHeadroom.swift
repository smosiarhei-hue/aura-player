import Foundation

/// Graphic EQ master gain. Always unity: a raised band gets louder, a cut gets
/// quieter. Compensating the whole song by the curve peak made every boost
/// turn the mix down.
public enum EQHeadroom {
    public static func preamp(gains: [Float], sampleRate: Double) -> Float {
        _ = gains
        _ = sampleRate
        return 0
    }
}
