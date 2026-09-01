import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class SpectrumAnalyzer {
    static let shared = SpectrumAnalyzer()
    nonisolated static let bandCount = 32

    private(set) var bands: [Float] = Array(repeating: 0, count: bandCount)
    private(set) var bass: Float = 0
    private(set) var mids: Float = 0
    private(set) var highs: Float = 0
    private(set) var level: Float = 0
    private(set) var streamLevel: Float = 0

    nonisolated private static let processor = SpectrumDSP()

    private init() {}

    nonisolated static func ingest(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let snapshot = processor.process(buffer: buffer, sampleRate: sampleRate) else { return }
        Task { @MainActor in
            let analyzer = SpectrumAnalyzer.shared
            analyzer.bands = snapshot.bands
            analyzer.bass = snapshot.bass
            analyzer.mids = snapshot.mids
            analyzer.highs = snapshot.highs
            analyzer.level = snapshot.level
        }
    }

    nonisolated static func ingestStreamLevel(_ rawLevel: Float) {
        guard let value = processor.processStreamLevel(rawLevel) else { return }
        Task { @MainActor in
            let analyzer = SpectrumAnalyzer.shared
            analyzer.streamLevel = value
            // Derive smooth dynamic frequency approximations when streaming
            let alpha: Float = 0.20
            analyzer.bass = analyzer.bass * (1 - alpha) + value * 0.9 * alpha
            analyzer.mids = analyzer.mids * (1 - alpha) + value * 0.6 * alpha
            analyzer.highs = analyzer.highs * (1 - alpha) + value * 0.4 * alpha
        }
    }

    func reset() {
        Self.processor.reset()
        bands = Array(repeating: 0, count: Self.bandCount)
        bass = 0
        mids = 0
        highs = 0
        level = 0
        streamLevel = 0
    }
}

nonisolated private struct SpectrumSnapshot: Sendable {
    let bands: [Float]
    let bass: Float
    let mids: Float
    let highs: Float
    let level: Float
}

nonisolated private final class SpectrumDSP: @unchecked Sendable {
    private let lock = NSLock()
    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var displayValues = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var smoothedBass: Float = 0
    private var smoothedMids: Float = 0
    private var smoothedHighs: Float = 0
    private var lastPublish = Date.distantPast
    private var streamLastPublish = Date.distantPast

    init() {
        let size = 1024
        let exponent: vDSP_Length = 10
        fftSetup = vDSP_create_fftsetup(exponent, FFTRadix(kFFTRadix2))
        window = (0..<size).map { index in
            let angle = 2 * Float.pi * Float(index) / Float(size - 1)
            return 0.5 * (1 - cos(angle))
        }
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func process(buffer: AVAudioPCMBuffer, sampleRate: Double) -> SpectrumSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let setup = fftSetup,
              buffer.frameLength >= vDSP_Length(fftSize),
              let channel = buffer.floatChannelData?[0] else { return nil }

        var input = [Float](repeating: 0, count: fftSize)
        for index in input.indices {
            input[index] = channel[index] * window[index]
        }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                input.withUnsafeBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: fftSize / 2
                    ) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                magnitudes.withUnsafeMutableBufferPointer { magnitudePointer in
                    vDSP_zvabs(
                        &split,
                        1,
                        magnitudePointer.baseAddress!,
                        1,
                        vDSP_Length(fftSize / 2)
                    )
                }

                let minimumFrequency: Float = 30
                let maximumFrequency: Float = 16_000
                let nyquist = Float(sampleRate) / 2
                let binCount = fftSize / 2
                var values = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
                var counts = [Int](repeating: 0, count: SpectrumAnalyzer.bandCount)

                for bin in 1..<binCount {
                    let frequency = Float(bin) * nyquist / Float(binCount)
                    guard frequency >= minimumFrequency else { continue }
                    guard frequency <= maximumFrequency else { break }
                    let position = log2(frequency / minimumFrequency) / log2(maximumFrequency / minimumFrequency)
                    let band = min(
                        SpectrumAnalyzer.bandCount - 1,
                        max(0, Int(position * Float(SpectrumAnalyzer.bandCount)))
                    )
                    let decibels = 20 * log10(magnitudes[bin] / 1024 + 1e-7)
                    values[band] += max(0, min(1, (decibels + 70) / 60))
                    counts[band] += 1
                }

                for band in values.indices where counts[band] > 0 {
                    values[band] /= Float(counts[band])
                    displayValues[band] = max(values[band], displayValues[band] * 0.86)
                }
            }
        }

        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 1 / 30 else { return nil }
        lastPublish = now

        let rawBass = displayValues.prefix(4).reduce(0, +) / 4.0
        let rawMids = displayValues[4..<min(18, displayValues.count)].reduce(0, +) / 14.0
        let rawHighs = displayValues[min(18, displayValues.count)..<displayValues.count].reduce(0, +) / 14.0
        let level = displayValues.reduce(0, +) / Float(SpectrumAnalyzer.bandCount)

        // Double Exponential LERP Smoothing (alpha = 0.18)
        let alpha: Float = 0.18
        smoothedBass = smoothedBass * (1.0 - alpha) + rawBass * alpha
        smoothedMids = smoothedMids * (1.0 - alpha) + rawMids * alpha
        smoothedHighs = smoothedHighs * (1.0 - alpha) + rawHighs * alpha

        return SpectrumSnapshot(
            bands: displayValues,
            bass: smoothedBass,
            mids: smoothedMids,
            highs: smoothedHighs,
            level: level
        )
    }

    func processStreamLevel(_ rawLevel: Float) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(streamLastPublish) > 1 / 30 else { return nil }
        streamLastPublish = now
        return max(0, min(1, rawLevel * 6))
    }

    func reset() {
        lock.lock()
        displayValues = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        lastPublish = .distantPast
        streamLastPublish = .distantPast
        lock.unlock()
    }
}
