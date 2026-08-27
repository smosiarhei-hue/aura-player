import AVFoundation
import Foundation
import MediaToolbox

@MainActor
final class StreamBeatTap {
    static let shared = StreamBeatTap()

    private var tapReference: MTAudioProcessingTap?

    private init() {}

    func attach(to item: AVPlayerItem) {
        item.allowedAudioSpatializationFormats = .monoAndStereo

        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            configureTap(for: item, track: track)
        }
    }

    private func configureTap(for item: AVPlayerItem, track: AVAssetTrack) {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: { _, _, _ in },
            finalize: { _ in },
            prepare: { _, _, _ in },
            unprepare: { _ in },
            process: { tap, frameCount, _, bufferList, outputFrameCount, flags in
                guard noErr == MTAudioProcessingTapGetSourceAudio(
                    tap,
                    frameCount,
                    bufferList,
                    flags,
                    nil,
                    outputFrameCount
                ) else { return }

                var accumulatedLevel: Float = 0
                var sampleCount = 0

                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    guard let data = buffer.mData else { continue }
                    let channels = max(Int(buffer.mNumberChannels), 1)
                    let frames = max(Int(outputFrameCount.pointee), 1)
                    let estimatedSamples = channels * frames
                    let bytesPerSample = estimatedSamples > 0
                        ? Int(buffer.mDataByteSize) / estimatedSamples
                        : 0

                    if bytesPerSample == MemoryLayout<Float>.size {
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.assumingMemoryBound(to: Float.self)
                        for index in 0..<count {
                            accumulatedLevel += abs(samples[index])
                        }
                        sampleCount += count
                    } else if bytesPerSample == MemoryLayout<Int16>.size {
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                        let samples = data.assumingMemoryBound(to: Int16.self)
                        for index in 0..<count {
                            accumulatedLevel += Float(abs(Int32(samples[index]))) / 32_768
                        }
                        sampleCount += count
                    }
                }

                guard sampleCount > 0 else { return }
                SpectrumAnalyzer.ingestStreamLevel(accumulatedLevel / Float(sampleCount))
            }
        )

        var createdTap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &createdTap
        ) == noErr, let createdTap else { return }

        tapReference = createdTap
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = createdTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }
}
