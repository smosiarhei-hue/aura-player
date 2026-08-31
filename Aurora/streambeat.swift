@preconcurrency import AVFoundation
import Foundation

// The realtime DSP callback lives in C, outside Swift actor isolation. The tap
// runs before AirPods Spatialize Stereo, so the user's EQ remains audible when
// system spatialization is enabled.
@MainActor
final class StreamBeatTap {
    static let shared = StreamBeatTap()
    private init() {}

    func attach(to item: AVPlayerItem) {
        item.allowedAudioSpatializationFormats = .monoAndStereo
        Task { @MainActor [weak item] in
            guard let item else { return }
            do {
                guard let track = try await item.asset.loadTracks(withMediaType: .audio).first,
                      let unmanagedTap = SonivoCreateStreamEQTap() else { return }
                let tap: MTAudioProcessingTap = unmanagedTap.takeRetainedValue()
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                item.audioMix = mix
            } catch {
                print("Stream EQ attachment failed: \(error)")
            }
        }
    }

    func updateEQ(enabled: Bool, gains: [Float]) {
        SonivoStreamEQSetEnabled(enabled)
        gains.withUnsafeBufferPointer { pointer in
            SonivoStreamEQSetGains(pointer.baseAddress, Int32(pointer.count))
        }
    }
}
