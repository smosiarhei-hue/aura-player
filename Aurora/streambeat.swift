@preconcurrency import AVFoundation
import Foundation

// MARK: - Streaming Beat Tap
//
// MTAudioProcessingTap invokes its lifecycle callbacks from private
// mediaplaybackd XPC queues. With Swift 6 default MainActor isolation on iOS 27
// beta, those imported C callbacks can retain an executor precondition and trap
// at runtime before audio starts. Streaming playback does not depend on this
// analyzer, so keep attachment deliberately inert until the tap is moved into a
// separately compiled nonisolated C/DSP target. Local-file spectrum analysis
// continues to work through PlayerCore's AVAudioEngine tap.

@MainActor
final class StreamBeatTap {
    static let shared = StreamBeatTap()

    private init() {}

    func attach(to item: AVPlayerItem) {
        // Spatial playback remains limited to formats that do not rewrite the
        // source channel layout. No MTAudioProcessingTap is installed here.
        item.allowedAudioSpatializationFormats = .monoAndStereo
        SpectrumAnalyzer.ingestStreamLevel(0)
    }
}
