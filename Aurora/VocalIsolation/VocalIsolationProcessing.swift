// Path: Aurora/VocalIsolation/VocalIsolationProcessing.swift

import Foundation
import Accelerate

// MARK: - 1. Vocal Isolation Processing Protocol
//
// Designed according to Section 2.3 of the specification:
// The DSP Mid/Side isolation block is encapsulated behind this protocol,
// allowing seamless drop-in replacement with a Core ML Neural Engine model
// (e.g. Conv-TasNet / Demucs-lite) without altering the UI or audio graph.

public protocol VocalIsolationProcessing: Sendable {
    /// Processes interleaved or non-interleaved stereo PCM audio samples in-place.
    /// - Parameters:
    ///   - leftChannel: Pointer to Left channel Float32 samples.
    ///   - rightChannel: Pointer to Right channel Float32 samples.
    ///   - frameCount: Number of audio frames in the buffer.
    ///   - isolationLevel: Attenuation factor: 0.0 (original mix) to 1.0 (vocal canceled).
    ///     Negative values (-1.0 .. 0.0) boost the center vocal presence.
    func process(
        leftChannel: UnsafeMutablePointer<Float>,
        rightChannel: UnsafeMutablePointer<Float>,
        frameCount: Int,
        isolationLevel: Float
    )
}

// MARK: - 2. Mid-Side Vocal Isolator (Real-Time DSP)
//
// Center-channel attenuation algorithm:
// In most studio mixes, the lead vocal is panned center: L_vocal = R_vocal.
// Mid = (L + R) / 2
// Side = (L - R) / 2
//
// Pure center cancellation (L - R) removes the vocal completely, but also cancels
// the kick drum, bass guitar, and sub-bass frequencies which are also centered.
// To preserve punch and audio fidelity:
// 1. A 1st-order IIR lowpass filter isolates low bass below ~220 Hz.
// 2. A 1st-order IIR highpass filter isolates high treble / air above ~7000 Hz.
// 3. Only the center vocal frequency band (220 Hz - 7 kHz) is attenuated:
//    Mid_vocal = Mid - Mid_bass - Mid_treble
//    Mid_vocal' = Mid_vocal * (1.0 - isolationLevel)
//    Mid' = Mid_bass + Mid_vocal' + Mid_treble
// 4. Reconstructed stereo:
//    L' = Mid' + Side
//    R' = Mid' - Side
//
// At isolationLevel = 0.0: Mid' == Mid, L' == L, R' == R (exact bit-for-bit passthrough).
// Parameter ramp (target vs current) is smoothed over ~30 ms to prevent clicks and pops.

public final class MidSideVocalIsolator: VocalIsolationProcessing, @unchecked Sendable {
    private var smoothedLevel: Float = 0.0
    private let rampFactor: Float = 0.005 // ~20-30 ms exponential smoothing at 44.1/48 kHz

    // Filter states for stereo channels to preserve bass and high air
    private var bassState: Float = 0.0
    private var trebleState: Float = 0.0

    // Filter coefficients for 48 kHz standard sample rate:
    // Bass cutoff ~220 Hz: alpha_bass = 2 * pi * dt * fc / (1 + 2 * pi * dt * fc) ~ 0.028
    // Treble cutoff ~7000 Hz: alpha_treble ~ 0.48
    private let alphaBass: Float = 0.028
    private let alphaTreble: Float = 0.48

    public init() {}

    public func process(
        leftChannel: UnsafeMutablePointer<Float>,
        rightChannel: UnsafeMutablePointer<Float>,
        frameCount: Int,
        isolationLevel: Float
    ) {
        guard frameCount > 0 else { return }

        // If both current and target are 0, completely bypass DSP for bit-exact passthrough
        if abs(smoothedLevel) < 0.0001 && abs(isolationLevel) < 0.0001 {
            return
        }

        let target = max(-1.0, min(1.0, isolationLevel))

        for i in 0..<frameCount {
            // Smooth parameter transition to eliminate clicking
            smoothedLevel += (target - smoothedLevel) * rampFactor

            let left = leftChannel[i]
            let right = rightChannel[i]

            // Mid-Side extraction
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5

            // Low-pass filter to preserve bass/kick drum below ~220 Hz
            bassState += alphaBass * (mid - bassState)
            let midBass = bassState

            // High-pass filter to preserve sparkling highs/air above ~7000 Hz
            trebleState += alphaTreble * (mid - trebleState)
            let midTreble = mid - trebleState

            // Vocal band (220 Hz - 7 kHz)
            let midVocal = mid - midBass - midTreble

            // Attenuate vocal band based on smoothed isolation level
            // When smoothedLevel = 1.0: vocal is attenuated to ~0
            // When smoothedLevel < 0.0: vocal is boosted for karaoke duet/practice
            let vocalGain = max(0.0, 1.0 - smoothedLevel)
            let processedMidVocal = midVocal * vocalGain

            // Reconstruct Mid with original bass and air intact
            let processedMid = midBass + processedMidVocal + midTreble

            // Reconstruct Left and Right
            // When smoothedLevel = 1.0: Side has full presence, center vocal is gone,
            // while bass and cymbals remain anchored.
            var outL = processedMid + side
            var outR = processedMid - side

            // Auto-makeup gain to prevent perceived volume drop when center is attenuated
            if smoothedLevel > 0.05 {
                let makeup = 1.0 + 0.15 * smoothedLevel
                outL *= makeup
                outR *= makeup
            }

            // Soft-clipper to prevent inter-sample clipping on intense masters
            leftChannel[i] = max(-1.0, min(1.0, outL))
            rightChannel[i] = max(-1.0, min(1.0, outR))
        }
    }
}

// MARK: - 3. ML Vocal Isolator (Core ML / Neural Engine Extension Placeholder)
//
// Conforms to Section 2.4 of the specification:
// Lightweight real-time ML model (Conv-TasNet / Demucs-lite) point of extension.
// When an on-device Core ML neural model is integrated in a future release,
// it plugs directly into this class without changing the UI or audio graph.

public final class MLVocalIsolator: VocalIsolationProcessing, @unchecked Sendable {
    private let fallback = MidSideVocalIsolator()
    private var isModelLoaded: Bool = false

    public init() {
        // TODO: Load compiled Core ML model (.mlmodelc) for Apple Neural Engine execution
    }

    public func process(
        leftChannel: UnsafeMutablePointer<Float>,
        rightChannel: UnsafeMutablePointer<Float>,
        frameCount: Int,
        isolationLevel: Float
    ) {
        if isModelLoaded {
            // TODO: Run real-time chunk inference on Apple Neural Engine
        } else {
            // High-performance DSP fallback
            fallback.process(
                leftChannel: leftChannel,
                rightChannel: rightChannel,
                frameCount: frameCount,
                isolationLevel: isolationLevel
            )
        }
    }
}
