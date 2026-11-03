import Foundation

/// Native music-player EQ headroom: always unity.
///
/// Broadband negative `globalGain` used to duck mids/vocals whenever bass was
/// boosted — heard as “bass muffles the song”. Match Apple Music–style EQ:
/// band filters only, no automatic master cut.
public enum EQHeadroom {
    public static func preamp(gains: [Float], sampleRate: Double) -> Float {
        _ = gains
        _ = sampleRate
        return 0
    }
}
