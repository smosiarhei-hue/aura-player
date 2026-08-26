import AVFoundation
import Foundation
import MediaToolbox

// MARK: - Real-time beat tap for streaming (AVPlayer) via MTAudioProcessingTap
//
// Local playback already feeds the FFT through the AVAudioEngine EQ tap.
// Streaming (AVPlayer) bypasses that engine, so we attach an audio processing
// tap to the AVPlayerItem to extract a live loudness level (beat proxy) and
// feed it into SpectrumAnalyzer.streamLevel.

final class StreamBeatTap {
    static let shared = StreamBeatTap()
    private var tapRef: Unmanaged<MTAudioProcessingTap>?

    // Format flag captured in `prepare`, read from `process` (both are global access).
    private static var isFloat = true

    func attach(to item: AVPlayerItem) {
        guard let track = item.asset.tracks(withMediaType: .audio).first else { return }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil
        ) { _, _, _ in
            // init
        } finalize: { _ in
            // finalize
        } prepare: { _, _, processingFormat in
            StreamBeatTap.isFloat = (processingFormat.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        } unprepare: { _ in
            // unprepare
        } process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
            guard noErr == MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut) else {
                return
            }
            var acc: Float = 0
            var count = 0
            for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
                guard let data = buffer.mData else { continue }
                let n = Int(buffer.mDataByteSize) / (StreamBeatTap.isFloat ? 4 : 2)
                if StreamBeatTap.isFloat {
                    let p = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<n { acc += abs(p[i]); count += 1 }
                } else {
                    let p = data.assumingMemoryBound(to: Int16.self)
                    for i in 0..<n { acc += Float(abs(Int32(p[i]))) / 32768.0; count += 1 }
                }
            }
            guard count > 0 else { return }
            SpectrumAnalyzer.shared.feedStreamLevel(acc / Float(count))
        }

        var tapOut: Unmanaged<MTAudioProcessingTap>?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tapOut) == noErr,
              let created = tapOut?.takeRetainedValue() else { return }
        tapRef = created

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = created
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }
}
