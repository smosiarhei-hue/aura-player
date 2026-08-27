import AVFoundation
import Foundation
import MediaToolbox

// MARK: - Real-time beat tap for streaming (AVPlayer) via MTAudioProcessingTap
// Also marks each AVPlayerItem as supporting stereo spatialization so compatible
// AirPods can offer the system Spatialize Stereo / head-tracking controls.

final class StreamBeatTap {
    static let shared = StreamBeatTap()
    private var tapRef: MTAudioProcessingTap?
    private static var isFloat = true

    func attach(to item: AVPlayerItem) {
        // Yandex delivers ordinary stereo MP3. This does not turn it into Dolby Atmos,
        // but explicitly allows Apple's headphone spatializer to process mono/stereo.
        item.allowedAudioSpatializationFormats = .monoAndStereo

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
            guard noErr == MTAudioProcessingTapGetSourceAudio(
                tap,
                numberFrames,
                bufferListInOut,
                flagsOut,
                nil,
                numberFramesOut
            ) else {
                return
            }

            var acc: Float = 0
            var count = 0
            for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
                guard let data = buffer.mData else { continue }
                let n = Int(buffer.mDataByteSize) / (StreamBeatTap.isFloat ? 4 : 2)
                if StreamBeatTap.isFloat {
                    let pointer = data.assumingMemoryBound(to: Float.self)
                    for index in 0..<n {
                        acc += abs(pointer[index])
                        count += 1
                    }
                } else {
                    let pointer = data.assumingMemoryBound(to: Int16.self)
                    for index in 0..<n {
                        acc += Float(abs(Int32(pointer[index]))) / 32768.0
                        count += 1
                    }
                }
            }

            guard count > 0 else { return }
            SpectrumAnalyzer.shared.feedStreamLevel(acc / Float(count))
        }

        var tapOut: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &tapOut
        ) == noErr, let created = tapOut else {
            return
        }

        tapRef = created
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = created
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }
}
