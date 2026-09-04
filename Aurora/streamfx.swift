@preconcurrency import AVFoundation
import Foundation

// MARK: - Stream FX (MTAudioProcessingTap)
//
// Yandex streams play through AVPlayer, which has no AVAudioUnit chain —
// so EQ bass-kills, filter sweeps and reverb/echo tails previously only
// worked on local files (AVAudioEngine), and streams got plain volume
// crossfades. MTAudioProcessingTap processes the decoded stream in-process,
// in place, on the audio thread: we run a DJ-style high-pass (low-end kill),
// a low-pass filter sweep and a feedback-delay echo tail. Parameters are
// ramped by PlayerCore.tickTransition exactly like the local AVAudioUnits.
//
// The processor is a nonisolated, @unchecked Sendable class: parameter
// floats are written from the main thread and read on the realtime thread.
// Aligned Float stores are atomic on arm64; no locks are taken on the
// audio thread (a lock there risks a priority-inversion stall).

nonisolated final class StreamFXProcessor: NSObject, @unchecked Sendable {
    // MARK: Parameters (main-thread writes, audio-thread reads)
    private var bassDepth: Float = 0   // 0...1, high-pass mix (bass kill)
    private var sweepDepth: Float = 0  // 0...1, low-pass sweep down
    private var echoMix: Float = 0    // 0...1, feedback-delay wetness

    // MARK: DSP state (audio thread only)
    private struct ChannelState {
        var hpX1: Float = 0, hpX2: Float = 0, hpY1: Float = 0, hpY2: Float = 0
        var lpX1: Float = 0, lpX2: Float = 0, lpY1: Float = 0, lpY2: Float = 0
        var ring: [Float] = []
        var ringPos: Int = 0
    }
    private var channels: [ChannelState] = []
    private var sampleRate: Double = 44_100
    private var echoDelayFrames: Int = 0

    override init() { super.init() }

    // MARK: Public API (main thread)

    func setFX(bassDepth: Float, sweepDepth: Float, echoMix: Float) {
        self.bassDepth = max(0, min(1, bassDepth))
        self.sweepDepth = max(0, min(1, sweepDepth))
        self.echoMix = max(0, min(1, echoMix))
    }

    func resetFX() {
        bassDepth = 0
        sweepDepth = 0
        echoMix = 0
    }

    /// Install this processor on a player item. Safe to call on every new
    /// item; a fresh tap is created each time and released with the item.
    func attach(to item: AVPlayerItem) {
        let retained = Unmanaged.passRetained(self).toOpaque()
        let initCallback: @convention(c) (MTAudioProcessingTap?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = {
            _, clientInfo, tapStorageOut in
            tapStorageOut?.pointee = clientInfo
        }
        let finalizeCallback: @convention(c) (MTAudioProcessingTap?) -> Void = { tap in
            guard let tap else { return }
            Unmanaged<StreamFXProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        }
        let prepareCallback: @convention(c) (MTAudioProcessingTap?, CMItemCount, UnsafePointer<AudioStreamBasicDescription>) -> Void = {
            tap, _, processingFormat in
            guard let tap else { return }
            let storage = MTAudioProcessingTapGetStorage(tap)
            let format = AVAudioFormat(streamDescription: processingFormat)
                ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
            if let format {
                Unmanaged<StreamFXProcessor>.fromOpaque(storage)
                    .takeUnretainedValue().prepare(format: format)
            }
        }
        let unprepareCallback: @convention(c) (MTAudioProcessingTap?) -> Void = { tap in
            guard let tap else { return }
            Unmanaged<StreamFXProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                .takeUnretainedValue().unprepare()
        }
        let processCallback: @convention(c) (MTAudioProcessingTap?, CMItemCount, MTAudioProcessingTapFlags, UnsafeMutablePointer<AudioBufferList>, UnsafeMutablePointer<CMItemCount>?, UnsafeMutablePointer<MTAudioProcessingTapFlags>?) -> Void = {
            tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
            guard let tap else {
                numberFramesOut?.pointee = numberFrames
                return
            }
            let processor = Unmanaged<StreamFXProcessor>
                .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let status = MTAudioProcessingTapGetSourceAudio(
                tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
            )
            guard status == noErr else { return }
            processor.process(frames: AVAudioFrameCount(numberFrames), bufferList: bufferListInOut)
        }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained,
            init: initCallback,
            finalize: finalizeCallback,
            prepare: prepareCallback,
            unprepare: unprepareCallback,
            process: processCallback
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tap else { return }

        let params = AVMutableAudioMixInputParameters()
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    // MARK: DSP lifecycle (audio thread)

    private func prepare(format: AVAudioFormat) {
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
        let channelCount = max(1, Int(format.channelCount))
        // ~0.27 s slap/echo delay, independent of tempo.
        echoDelayFrames = Int(sampleRate * 0.27)
        channels = (0..<channelCount).map { _ in
            var state = ChannelState()
            state.ring = [Float](repeating: 0, count: echoDelayFrames + 16)
            return state
        }
    }

    private func unprepare() {
        channels = []
    }

    private func process(frames: AVAudioFrameCount, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        // Snapshot parameters once per block — no allocation, no locks.
        let bass = bassDepth
        let sweep = sweepDepth
        let echo = echoMix
        guard bass > 0.001 || sweep > 0.001 || echo > 0.001 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let fs = sampleRate

        // High-pass (bass kill): RBJ cookbook, 110 Hz, Q 0.7.
        let hpCut: Double = 110
        let hpW0 = 2 * Double.pi * hpCut / fs
        let hpCos = cos(hpW0), hpSin = sin(hpW0)
        let hpAlpha = hpSin / (2 * 0.707)
        let hpA0 = 1 + hpAlpha
        let hpB0 = Float(((1 + hpCos) / 2) / hpA0)
        let hpB1 = Float((-(1 + hpCos)) / hpA0)
        let hpB2 = Float(((1 + hpCos) / 2) / hpA0)
        let hpA1 = Float((-2 * hpCos) / hpA0)
        let hpA2 = Float((1 - hpAlpha) / hpA0)

        // Low-pass sweep: cutoff moves 18 kHz -> 180 Hz as sweep 0 -> 1.
        let lpCut = 18_000.0 * pow(180.0 / 18_000.0, Double(sweep))
        let lpW0 = 2 * Double.pi * max(60, lpCut) / fs
        let lpCos = cos(lpW0), lpSin = sin(lpW0)
        let lpAlpha = lpSin / (2 * 0.707)
        let lpA0 = 1 + lpAlpha
        let lpB0 = Float(((1 - lpCos) / 2) / lpA0)
        let lpB1 = Float((1 - lpCos) / lpA0)
        let lpB2 = Float(((1 - lpCos) / 2) / lpA0)
        let lpA1 = Float((-2 * lpCos) / lpA0)
        let lpA2 = Float((1 - lpAlpha) / lpA0)

        let echoWet = echo * 0.5
        let echoFeedback: Float = 0.38

        for chIndex in 0..<buffers.count {
            guard chIndex < channels.count,
                  let data = buffers[chIndex].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = min(Int(frames), Int(buffers[chIndex].mDataByteSize) / MemoryLayout<Float>.size)
            guard count > 0 else { continue }

            var st = channels[chIndex]
            let ringCount = st.ring.count
            for i in 0..<count {
                let x = samples[i]

                // --- High-pass (bass kill), wet/dry crossfade ---
                let hpY = hpB0 * x + hpB1 * st.hpX1 + hpB2 * st.hpX2
                           - hpA1 * st.hpY1 - hpA2 * st.hpY2
                st.hpX2 = st.hpX1; st.hpX1 = x
                st.hpY2 = st.hpY1; st.hpY1 = hpY
                let bassOut = x * (1 - bass) + hpY * bass

                // --- Low-pass sweep ---
                let lpY = lpB0 * bassOut + lpB1 * st.lpX1 + lpB2 * st.lpX2
                           - lpA1 * st.lpY1 - lpA2 * st.lpY2
                st.lpX2 = st.lpX1; st.lpX1 = bassOut
                st.lpY2 = st.lpY1; st.lpY1 = lpY
                let sweptOut = bassOut * (1 - sweep) + lpY * sweep

                // --- Echo (feedback delay tail) ---
                var out = sweptOut
                if echoWet > 0.001, ringCount > 0 {
                    let delayed = st.ring[st.ringPos]
                    out = sweptOut + delayed * echoWet
                    st.ring[st.ringPos] = sweptOut + delayed * echoFeedback
                    st.ringPos += 1
                    if st.ringPos >= ringCount { st.ringPos = 0 }
                }

                samples[i] = max(-1.2, min(1.2, out))
            }
            channels[chIndex] = st
        }
    }
}
