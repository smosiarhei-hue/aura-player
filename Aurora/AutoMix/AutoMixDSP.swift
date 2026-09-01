import Accelerate
@preconcurrency import AVFoundation
import Foundation

// MARK: - Shared feature extraction
//
// One streaming pass over the decoded file produces everything the analyzers
// need: an onset (spectral flux) envelope, a per-frame RMS curve and an
// accumulated chroma vector. Reuses the same vDSP FFT wiring as
// spectrumanalyzer.swift instead of pulling in a new dependency.
//
// Streaming matters: a one hour file would need hundreds of megabytes if the
// whole waveform were kept in memory, while the feature arrays stay tiny.

nonisolated struct AudioFeatures: Sendable {
    let duration: Double
    let sampleRate: Double
    let hopSize: Int
    /// Spectral flux per analysis frame.
    let onset: [Float]
    /// RMS per analysis frame.
    let rms: [Float]
    /// 12 semitone bins, normalized to 0...1.
    let chroma: [Float]

    var frameRate: Double { sampleRate / Double(hopSize) }
}

nonisolated final class STFTProcessor {
    private let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup?
    private let window: [Float]

    init(size: Int) {
        self.size = size
        let exponent = vDSP_Length(log2(Double(size)).rounded())
        self.log2n = exponent
        self.setup = vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2))
        self.window = (0..<size).map { index in
            0.5 * (1 - cos(2 * Float.pi * Float(index) / Float(size - 1)))
        }
    }

    deinit {
        if let setup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func magnitudes(of frame: [Float]) -> [Float] {
        let half = size / 2
        var result = [Float](repeating: 0, count: half)
        guard let setup, frame.count >= size else { return result }

        var input = [Float](repeating: 0, count: size)
        for index in 0..<size {
            input[index] = frame[index] * window[index]
        }

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                input.withUnsafeBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: half
                    ) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                result.withUnsafeMutableBufferPointer { output in
                    vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        var scale = Float(1) / Float(size)
        var scaled = [Float](repeating: 0, count: half)
        vDSP_vsmul(result, 1, &scale, &scaled, 1, vDSP_Length(half))
        return scaled
    }
}

nonisolated enum AutoMixDSP {
    static let analysisSampleRate: Double = 22_050
    static let fftSize = 1024
    static let hopSize = 256

    /// Decode to mono 22.05 kHz and extract the shared feature set.
    nonisolated static func features(for url: URL) async -> AudioFeatures? {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: analysisSampleRate
        ]

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let stft = STFTProcessor(size: fftSize)
        let half = fftSize / 2

        var pending: [Float] = []
        pending.reserveCapacity(fftSize * 8)
        var onset: [Float] = []
        var rms: [Float] = []
        var chroma = [Float](repeating: 0, count: 12)
        var previous = [Float](repeating: 0, count: half)
        var totalSamples = 0

        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                )
                if let pointer, length >= 4 {
                    let count = length / 4
                    let floats = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
                    pending.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
                    totalSamples += count
                }
            }
            CMSampleBufferInvalidate(sample)

            while pending.count >= fftSize {
                let frame = Array(pending[0..<fftSize])

                var frameRMS: Float = 0
                vDSP_rmsqv(frame, 1, &frameRMS, vDSP_Length(fftSize))
                rms.append(frameRMS)

                let magnitudes = stft.magnitudes(of: frame)
                var flux: Float = 0
                for index in 1..<magnitudes.count {
                    let difference = magnitudes[index] - previous[index]
                    if difference > 0 { flux += difference }
                }
                onset.append(flux)
                accumulateChroma(&chroma, magnitudes: magnitudes)
                previous = magnitudes

                pending.removeFirst(hopSize)
            }
        }

        reader.cancelReading()

        guard onset.count > 16, totalSamples > Int(analysisSampleRate) else { return nil }

        let peak = chroma.max() ?? 0
        let normalizedChroma = peak > 0 ? chroma.map { $0 / peak } : chroma

        return AudioFeatures(
            duration: Double(totalSamples) / analysisSampleRate,
            sampleRate: analysisSampleRate,
            hopSize: hopSize,
            onset: onset,
            rms: rms,
            chroma: normalizedChroma
        )
    }

    /// Fold the spectrum into 12 semitone bins (HPCP style, 65 Hz - 2 kHz).
    nonisolated private static func accumulateChroma(_ chroma: inout [Float], magnitudes: [Float]) {
        let binCount = magnitudes.count
        guard binCount > 1 else { return }
        for bin in 1..<binCount {
            let frequency = Double(bin) * analysisSampleRate / Double(fftSize)
            guard frequency >= 65, frequency <= 2_000 else { continue }
            let midi = 69.0 + 12.0 * log2(frequency / 440.0)
            let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
            chroma[pitchClass] += magnitudes[bin]
        }
    }
}
