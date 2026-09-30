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
    private(set) var kick: Float = 0
    private(set) var mids: Float = 0
    private(set) var highs: Float = 0
    private(set) var level: Float = 0
    private(set) var streamLevel: Float = 0

    // MARK: - iOS 27 Audio-Reactive Kick / Bass Pulse (30-120 Hz)
    var dynamicKick: Float {
        // Real-time audio FFT kick transient has first priority and zero lag
        if level > 0.001 || kick > 0.005 {
            return min(1.0, kick)
        }
        if streamLevel > 0.02 {
            return min(1.0, streamLevel)
        }
        // Subtle, calm resting breath pulse for audio streams without PCM tap
        guard PlayerCore.shared.isPlaying else { return 0 }
        let tempo = PlayerCore.shared.currentTrack?.bpm ?? 120.0
        let beatInterval = 60.0 / max(60.0, min(180.0, tempo))
        let phase = fmod(PlayerCore.shared.progress, beatInterval) / beatInterval
        if phase < 0.24 {
            let s = phase / 0.24
            return Float(0.18 * (1.0 + cos(s * .pi)))
        }
        return 0.0
    }

    var dynamicBass: Float {
        if level > 0.001 || bass > 0.005 {
            return min(1.0, bass)
        }
        return dynamicKick * 0.65
    }

    nonisolated private static let processor = SpectrumDSP()
    private init() {}

    nonisolated static func ingest(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let snapshot = processor.process(buffer: buffer, sampleRate: sampleRate) else { return }
        Task { @MainActor in
            let analyzer = SpectrumAnalyzer.shared
            analyzer.bands = snapshot.bands
            analyzer.bass = snapshot.bass
            analyzer.kick = snapshot.kick
            analyzer.mids = snapshot.mids
            analyzer.highs = snapshot.highs
            analyzer.level = snapshot.level
        }
    }

    nonisolated static func ingestStreamLevel(_ rawLevel: Float) {
        guard let value = processor.processStreamLevel(rawLevel) else { return }
        Task { @MainActor in SpectrumAnalyzer.shared.streamLevel = value }
    }

    func reset() {
        Self.processor.reset()
        MusicHapticsManager.shared.reset()
        bands = Array(repeating: 0, count: Self.bandCount)
        bass = 0; kick = 0; mids = 0; highs = 0; level = 0; streamLevel = 0
    }
}

nonisolated private struct SpectrumSnapshot: Sendable {
    let bands: [Float]; let bass: Float; let kick: Float
    let mids: Float; let highs: Float; let level: Float
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
    private var bassBaseline: Float = 0
    private var kickEnvelope: Float = 0
    private var lastPublish = Date.distantPast
    private var streamLastPublish = Date.distantPast

    init() {
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        window = (0..<1024).map { index in
            let angle = 2 * Float.pi * Float(index) / 1023
            return 0.5 * (1 - cos(angle))
        }
    }
    deinit { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

    func process(buffer: AVAudioPCMBuffer, sampleRate: Double) -> SpectrumSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let setup = fftSetup, buffer.frameLength >= vDSP_Length(fftSize),
              let channel = buffer.floatChannelData?[0] else { return nil }
        var input = [Float](repeating: 0, count: fftSize)
        for index in input.indices { input[index] = channel[index] * window[index] }
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imaginary.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var magnitudes = [Float](repeating: 0, count: fftSize / 2)
                magnitudes.withUnsafeMutableBufferPointer {
                    vDSP_zvabs(&split, 1, $0.baseAddress!, 1, vDSP_Length(fftSize / 2))
                }
                let minimum: Float = 30, maximum: Float = 16_000
                let nyquist = Float(sampleRate) / 2
                var values = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
                var counts = [Int](repeating: 0, count: SpectrumAnalyzer.bandCount)
                for bin in 1..<(fftSize / 2) {
                    let frequency = Float(bin) * nyquist / Float(fftSize / 2)
                    guard frequency >= minimum else { continue }
                    guard frequency <= maximum else { break }
                    let position = log2(frequency / minimum) / log2(maximum / minimum)
                    let band = min(SpectrumAnalyzer.bandCount - 1,
                                   max(0, Int(position * Float(SpectrumAnalyzer.bandCount))))
                    let db = 20 * log10(magnitudes[bin] / 1024 + 1e-7)
                    values[band] += max(0, min(1, (db + 70) / 60)); counts[band] += 1
                }
                for band in values.indices where counts[band] > 0 {
                    values[band] /= Float(counts[band])
                    displayValues[band] = max(values[band], displayValues[band] * 0.80)
                }
                MusicHapticsManager.core.processRawBands(values)
            }
        }
        let now = Date()
        guard now.timeIntervalSince(lastPublish) > 1 / 120 else { return nil }
        lastPublish = now

        // Logarithmic bands 0...7 cover approximately 30...120 Hz. The
        // transient detector weights 30...70 Hz most strongly, while the
        // upper low-bass region makes the colour bloom smoother and fuller.
        let sub = displayValues[0..<4].reduce(0, +) / 4
        let punch = displayValues[4..<8].reduce(0, +) / 4
        let rawBass = min(1, sub * 0.68 + punch * 0.52)
        let rawMids = displayValues[8..<18].reduce(0, +) / 10
        let rawHighs = displayValues[18..<displayValues.count].reduce(0, +) / 14
        let level = displayValues.reduce(0, +) / Float(SpectrumAnalyzer.bandCount)

        let previousBaseline = bassBaseline
        bassBaseline = bassBaseline * 0.92 + rawBass * 0.08
        let onset = max(0, rawBass - previousBaseline)
        let gated: Float = rawBass > 0.045
            ? min(1.0, onset * 8.5 + max(0, sub - 0.20) * 1.6 + max(0, punch - 0.24) * 1.0)
            : 0
        kickEnvelope = max(gated, kickEnvelope * 0.82)
        let alpha: Float = 0.28
        smoothedBass = smoothedBass * (1 - alpha) + rawBass * alpha
        smoothedMids = smoothedMids * (1 - alpha) + rawMids * alpha
        smoothedHighs = smoothedHighs * (1 - alpha) + rawHighs * alpha
        return SpectrumSnapshot(bands: displayValues, bass: smoothedBass,
                                kick: kickEnvelope, mids: smoothedMids,
                                highs: smoothedHighs, level: level)
    }

    func processStreamLevel(_ rawLevel: Float) -> Float? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(streamLastPublish) > 1 / 30 else { return nil }
        streamLastPublish = now
        return max(0, min(1, rawLevel * 6))
    }
    func reset() {
        lock.lock()
        displayValues = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        smoothedBass = 0; smoothedMids = 0; smoothedHighs = 0
        bassBaseline = 0; kickEnvelope = 0
        lastPublish = .distantPast; streamLastPublish = .distantPast
        lock.unlock()
    }
}
