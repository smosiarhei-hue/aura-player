// Reference from commit 9a2f042ffe062043dcb0dc7b3607c2ec453618aa. Test fixture only.
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
    private var beatWaveDetector = BeatWaveKickDetector()
    private var previousMediaTime: TimeInterval?
    private var spectralFlux=BeatWaveSpectralFlux()
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

    func process(buffer: AVAudioPCMBuffer, sampleRate: Double,capturedAt: TimeInterval?,mediaTime: TimeInterval?,observedAt suppliedObservation: TimeInterval? = nil) -> SpectrumSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let setup = fftSetup, buffer.frameLength >= vDSP_Length(fftSize),
              let channel = buffer.floatChannelData?[0] else { return nil }
        let observedAt=suppliedObservation ?? Date.timeIntervalSinceReferenceDate
        var beatFrame = BeatWaveAudioFrame(capturedAt: capturedAt ?? observedAt)
        beatFrame.mediaTime=mediaTime
        if let mediaTime {
            if let previousMediaTime,mediaTime<previousMediaTime || mediaTime-previousMediaTime>0.5 {
                beatWaveDetector.reset()
                spectralFlux.reset()
            }
            previousMediaTime=mediaTime
        } else { previousMediaTime=nil }
        var rmsSum: Float = 0
        for i in 0..<fftSize { rmsSum += channel[i] * channel[i] }
        beatFrame.rms = min(1, sqrt(rmsSum/Float(fftSize))*1.8)
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
                let flux=spectralFlux.process(magnitudes: magnitudes,sampleRate: sampleRate)
                beatFrame.bassFlux=flux.bass; beatFrame.attackFlux=flux.attack
                // Reuse the already-decoded PCM/spectrum, never load another copy of the song.
                beatFrame.subBass = BeatWaveBandEnergy.mean(values: values,counts: counts,range: 0..<4)
                beatFrame.bass = BeatWaveBandEnergy.mean(values: values,counts: counts,range: 4..<9)
                beatFrame.lowMids = BeatWaveBandEnergy.mean(values: values,counts: counts,range: 9..<15)
                beatFrame.mids = BeatWaveBandEnergy.mean(values: values,counts: counts,range: 15..<25)
                beatFrame.highs = BeatWaveBandEnergy.mean(values: values,counts: counts,range: 25..<32)
                var detectorFrame=beatFrame
                detectorFrame.capturedAt=mediaTime ?? beatFrame.capturedAt
                beatWaveDetector.process(detectorFrame)
                beatFrame.kickEventID = beatWaveDetector.eventID
                beatFrame.kickEnvelope = beatWaveDetector.envelope
                beatFrame.kickConfidence = beatWaveDetector.confidence
                MusicHapticsManager.core.processRawBands(values)
            }
        }
        let now = Date()
        let updatesDisplay=now.timeIntervalSince(lastPublish)>1/120
        if updatesDisplay { lastPublish=now }

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
        let gated: Float = rawBass > 0.045 && onset > max(0.015, previousBaseline * 0.08)
            ? min(1.0, onset * 8.5)
            : 0
        kickEnvelope = max(gated, kickEnvelope * 0.82)
        // Asymmetric envelopes make the visual response feel physical:
        // transients arrive immediately, while energy dissipates with inertia.
        let bassAlpha: Float = rawBass > smoothedBass ? 0.34 : 0.105
        let midsAlpha: Float = rawMids > smoothedMids ? 0.27 : 0.082
        let highsAlpha: Float = rawHighs > smoothedHighs ? 0.22 : 0.060
        smoothedBass += (rawBass - smoothedBass) * bassAlpha
        smoothedMids += (rawMids - smoothedMids) * midsAlpha
        smoothedHighs += (rawHighs - smoothedHighs) * highsAlpha
        return SpectrumSnapshot(bands: displayValues, bass: smoothedBass,
                                kick: kickEnvelope, mids: smoothedMids,
                                highs: smoothedHighs, level: level, beatWaveFrame: beatFrame,observedAt: observedAt,updatesDisplay: updatesDisplay)
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
        beatWaveDetector.reset(); previousMediaTime=nil
        spectralFlux.reset()
        lastPublish = .distantPast; streamLastPublish = .distantPast
        lock.unlock()
    }
}
