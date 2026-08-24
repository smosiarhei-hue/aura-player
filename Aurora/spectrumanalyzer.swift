import Accelerate
import AVFoundation
import Combine
import Foundation

final class SpectrumAnalyzer: ObservableObject {
    static let shared = SpectrumAnalyzer()
    static let bandCount = 32

    @Published private(set) var bands: [Float] = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
    @Published private(set) var bass: Float = 0
    @Published private(set) var level: Float = 0

    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private var fftSetup: FFTSetup? = nil
    private var window: [Float] = []
    private var displayValues = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var lastPublish = Date.distantPast

    private init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = (0..<fftSize).map { i in
            let angle = 2.0 * Float.pi * Float(i) / Float(fftSize - 1)
            return 0.5 * (1 - cos(angle))
        }
    }

    func process(buffer: AVAudioPCMBuffer, sampleRate sr: Double) {
        guard let setup = fftSetup else { return }
        guard buffer.frameLength >= vDSP_Length(fftSize),
              let channel = buffer.floatChannelData?[0] else { return }

        // Windowed copy
        var input = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize { input[i] = channel[i] * window[i] }

        // Real FFT via vDSP
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                input.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTRadix(kFFTRadixForward))

                var mags = [Float](repeating: 0, count: fftSize / 2)
                mags.withUnsafeMutableBufferPointer { magsPtr in
                    vDSP_zvabs(&split, 1, magsPtr.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }

                // Map 512 bins → 32 log bands (30 Hz … 16 kHz)
                let minFreq: Float = 30, maxFreq: Float = 16000
                let nyquist = Float(sr) / 2
                let binCount = fftSize / 2
                var newValues = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
                var counts = [Int](repeating: 0, count: SpectrumAnalyzer.bandCount)
                for bin in 1..<binCount {
                    let f = Float(bin) * nyquist / Float(binCount)
                    guard f >= minFreq else { continue }
                    guard f <= maxFreq else { break }
                    let t = log2(f / minFreq) / log2(maxFreq / minFreq)
                    let idx = min(SpectrumAnalyzer.bandCount - 1, max(0, Int(t * Float(SpectrumAnalyzer.bandCount))))
                    let v = 20 * log10(mags[bin] / 1024 + 1e-7)
                    let norm = max(0, min(1, (v + 70) / 60))
                    newValues[idx] += norm
                    counts[idx] += 1
                }
                for i in 0..<SpectrumAnalyzer.bandCount where counts[i] > 0 {
                    newValues[i] /= Float(counts[i])
                    displayValues[i] = max(newValues[i], displayValues[i] * 0.86)
                }
            }
        }

        // Throttle publish to ~30 Hz on main queue
        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 0.033 else { return }
        lastPublish = now
        let snapshot = displayValues
        let b = (displayValues[0] + displayValues[1] + displayValues[2]) / 3
        let l = displayValues.reduce(0, +) / Float(SpectrumAnalyzer.bandCount)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bands = snapshot
            self.bass = b
            self.level = l
        }
    }

    func reset() {
        let zeros = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        DispatchQueue.main.async { [weak self] in
            self?.bands = zeros
            self?.bass = 0
            self?.level = 0
        }
    }
}
