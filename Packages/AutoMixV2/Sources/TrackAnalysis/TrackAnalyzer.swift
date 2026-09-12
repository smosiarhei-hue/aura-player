// Path: Packages/AutoMixV2/Sources/TrackAnalysis/TrackAnalyzer.swift

@preconcurrency import AVFAudio
import Accelerate
import CryptoKit
import Foundation
import MixModels

public enum TrackAnalysisError: Error, Sendable, Equatable {
    case invalidAudioFormat
    case cannotCreateConverter
    case cannotCreateBuffer
    case conversionFailed(String)
    case noAudioSamples
}

public actor TrackAnalyzer {
    private let storageDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    public func profile(for id: TrackID, fileURL: URL) async throws -> TrackProfile {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let destination = profileURL(for: id)
        if let data = try? Data(contentsOf: destination),
           let cached = try? decoder.decode(TrackProfile.self, from: data),
           cached.profileVersion == TrackProfile.currentVersion {
            return cached
        }
        let profile = try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try TrackAnalysisComputer.analyze(id: id, fileURL: fileURL)
        }.value
        try Task.checkCancellation()
        let data = try encoder.encode(profile)
        try data.write(to: destination, options: .atomic)
        return profile
    }

    public func removeProfile(for id: TrackID) throws {
        let url = profileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func profileURL(for id: TrackID) -> URL {
        let digest = SHA256.hash(data: Data(id.raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return storageDirectory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    public static func defaultStorageDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return root.appendingPathComponent("profiles", isDirectory: true)
    }
}

public enum TrackAnalysisAlgorithms {
    public static func estimateTempo(samples: [Float], sampleRate: Double) -> (bpm: Float, confidence: Float) {
        TempoDetector.estimate(samples: samples, sampleRate: sampleRate)
    }
}

private enum TrackAnalysisComputer {
    static func analyze(id: TrackID, fileURL: URL) throws -> TrackProfile {
        try Task.checkCancellation()
        let source = try AVAudioFile(forReading: fileURL)
        let sourceRate = source.processingFormat.sampleRate
        guard sourceRate > 0 else { throw TrackAnalysisError.invalidAudioFormat }
        let duration = Double(source.length) / sourceRate

        let rhythm = try AudioDecoder.decodeMono(fileURL: fileURL, sampleRate: 22_050)
        try Task.checkCancellation()
        let loudness = try AudioDecoder.decodeMono(fileURL: fileURL, sampleRate: 48_000)
        try Task.checkCancellation()
        guard !rhythm.isEmpty, !loudness.isEmpty else { throw TrackAnalysisError.noAudioSamples }

        let tempo = TempoDetector.estimate(samples: rhythm, sampleRate: 22_050)
        let beatPeriod = tempo.bpm > 0 ? 60.0 / Double(tempo.bpm) : 0
        let phase = TempoDetector.bestPhase(samples: rhythm, sampleRate: 22_050, period: beatPeriod)
        let beats = beatPeriod > 0 ? stride(from: phase, through: duration, by: beatPeriod).map { $0 } : []
        let downbeatPhase = TempoDetector.downbeatPhase(samples: rhythm, sampleRate: 22_050, beats: beats)
        let downbeats = beats.enumerated().compactMap { index, value in
            index % 4 == downbeatPhase ? value : nil
        }
        let phraseStarts = downbeats.enumerated().compactMap { index, value in index % 8 == 0 ? value : nil }
        try Task.checkCancellation()

        let weighted = LoudnessMeter.kWeighted(loudness, sampleRate: 48_000)
        let loudnessResult = LoudnessMeter.measure(weighted, sampleRate: 48_000)
        let energy = EnergyMeter.curve(loudness, sampleRate: 48_000)
        let hasFade = EnergyMeter.hasFadeOut(loudness, sampleRate: 48_000)
        let endsSilent = EnergyMeter.endsInSilence(loudness, sampleRate: 48_000)
        let segments = CueDetector.segments(energy: energy, duration: duration, endsSilent: endsSilent)
        let cues = CueDetector.cues(duration: duration, energy: energy,
                                    downbeats: downbeats, phrases: phraseStarts,
                                    hasFadeOut: hasFade)
        let stability: Float = beats.count >= 2 ? 1 : 0
        let downbeatConfidence = min(1, tempo.confidence * 0.9)
        let confidence = Confidence(bpm: tempo.confidence, downbeats: downbeatConfidence, key: 0)
        let mixable = confidence.bpm >= 0.7 && stability >= 0.9 && beats.count >= 64

        return TrackProfile(trackID: id, durationSec: duration,
                            sourceSampleRate: sourceRate, sourceBitrateKbps: nil,
                            bpm: tempo.bpm, beatsSec: beats, downbeatsSec: downbeats,
                            phraseStartsSec: phraseStarts, tempoStability: stability,
                            camelotKey: nil, integratedLUFS: loudnessResult.integrated,
                            loudnessCurveLUFS: loudnessResult.curve, energyCurve: energy,
                            hasFadeOut: hasFade, endsInSilence: endsSilent,
                            vocalPresence: [], segments: segments,
                            mixInSec: cues.mixIn, mixOutSec: cues.mixOut,
                            mixable: mixable, confidence: confidence)
    }
}

private enum AudioDecoder {
    static func decodeMono(fileURL: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw TrackAnalysisError.cannotCreateConverter
        }
        var result: [Float] = []
        var reachedEnd = false
        while !reachedEnd {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw TrackAnalysisError.cannotCreateBuffer
            }
            var inputError: Error?
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                if file.framePosition >= file.length {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = max(1, min(requested, 4_096))
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                    inputError = TrackAnalysisError.cannotCreateBuffer
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: count)
                    if input.frameLength == 0 {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return input
                } catch {
                    inputError = error
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }
            if let inputError { throw inputError }
            if status == .error {
                throw TrackAnalysisError.conversionFailed(error?.localizedDescription ?? "Audio conversion failed")
            }
            reachedEnd = status == .endOfStream
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            } else if !reachedEnd {
                throw TrackAnalysisError.conversionFailed("Converter made no progress")
            }
        }
        return result
    }
}

private enum TempoDetector {
    static func estimate(samples: [Float], sampleRate: Double) -> (bpm: Float, confidence: Float) {
        guard sampleRate > 0, samples.count > 2_048 else { return (0, 0) }
        let frame = 1_024
        let hop = 256
        var onset: [Float] = []
        var previous: Float = 0
        var index = 0
        while index + frame <= samples.count {
            var square: Float = 0
            vDSP_svesq(Array(samples[index..<(index + frame)]), 1, &square, vDSP_Length(frame))
            let rms = sqrt(max(square / Float(frame), 0))
            onset.append(max(0, log1p(rms * 100) - previous))
            previous = log1p(rms * 100)
            index += hop
        }
        guard onset.count > 8 else { return (0, 0) }
        let onsetRate = sampleRate / Double(hop)
        let minLag = max(1, Int(onsetRate * 60 / 200))
        let maxLag = min(onset.count / 2, Int(onsetRate * 60 / 60))
        var candidates: [(lag: Int, score: Double)] = []
        for lag in minLag...maxLag {
            var sum = 0.0
            for i in lag..<onset.count { sum += Double(onset[i] * onset[i - lag]) }
            let bpm = 60 * onsetRate / Double(lag)
            let prior = exp(-0.5 * pow(log(bpm / 120) / 0.45, 2))
            candidates.append((lag, sum * (0.75 + 0.25 * prior)))
        }
        guard let best = candidates.max(by: { $0.score < $1.score }), best.score > 0 else { return (0, 0) }
        let separated = candidates.filter { abs($0.lag - best.lag) > 2 }
        let second = separated.max(by: { $0.score < $1.score })?.score ?? 0
        let ratio = best.score / max(second, best.score * 0.01)
        let confidence = Float(min(1, max(0, (ratio - 1) * 2.5 + 0.65)))
        return (Float(60 * onsetRate / Double(best.lag)), confidence)
    }

    static func bestPhase(samples: [Float], sampleRate: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let steps = 64
        var bestPhase = 0.0
        var bestScore: Float = -.greatestFiniteMagnitude
        for step in 0..<steps {
            let phase = period * Double(step) / Double(steps)
            var score: Float = 0
            var time = phase
            while Int(time * sampleRate) < samples.count {
                let center = Int(time * sampleRate)
                let radius = max(1, Int(0.015 * sampleRate))
                let lo = max(0, center - radius), hi = min(samples.count, center + radius)
                if lo < hi { score += samples[lo..<hi].map { abs($0) }.max() ?? 0 }
                time += period
            }
            if score > bestScore { bestScore = score; bestPhase = phase }
        }
        return bestPhase
    }

    static func downbeatPhase(samples: [Float], sampleRate: Double, beats: [Double]) -> Int {
        guard beats.count >= 4 else { return 0 }
        var scores = Array(repeating: Float(0), count: 4)
        for (index, time) in beats.enumerated() {
            let sample = min(samples.count - 1, max(0, Int(time * sampleRate)))
            scores[index % 4] += abs(samples[sample])
        }
        return scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
    }
}

private enum LoudnessMeter {
    static func kWeighted(_ samples: [Float], sampleRate: Double) -> [Float] {
        var highPassed = Biquad.highPass(frequency: 38, sampleRate: sampleRate).process(samples)
        highPassed = Biquad.highShelf(frequency: 1_500, gainDB: 4, sampleRate: sampleRate).process(highPassed)
        return highPassed
    }

    static func measure(_ samples: [Float], sampleRate: Double) -> (integrated: Float, curve: [Float]) {
        let window = max(1, Int(sampleRate * 0.4))
        let step = max(1, Int(sampleRate * 0.1))
        var blocks: [(lufs: Float, energy: Double)] = []
        var start = 0
        while start + window <= samples.count {
            let energy = samples[start..<(start + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)
            let lufs = Float(-0.691 + 10 * log10(max(energy, 1e-12)))
            if lufs >= -70 { blocks.append((lufs, energy)) }
            start += step
        }
        guard !blocks.isEmpty else { return (-70, []) }
        let ungatedEnergy = blocks.map(\.energy).reduce(0, +) / Double(blocks.count)
        let ungated = Float(-0.691 + 10 * log10(max(ungatedEnergy, 1e-12)))
        let gated = blocks.filter { $0.lufs >= ungated - 10 }
        let chosen = gated.isEmpty ? blocks : gated
        let energy = chosen.map(\.energy).reduce(0, +) / Double(chosen.count)
        let integrated = Float(-0.691 + 10 * log10(max(energy, 1e-12)))
        let second = max(1, Int(sampleRate))
        var curve: [Float] = []
        for offset in stride(from: 0, to: samples.count, by: second) {
            let end = min(samples.count, offset + second)
            let e = samples[offset..<end].reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, end - offset))
            curve.append(Float(-0.691 + 10 * log10(max(e, 1e-12))))
        }
        return (integrated, curve)
    }
}

private struct Biquad {
    let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    func process(_ input: [Float]) -> [Float] {
        var output = Array(repeating: Float(0), count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in input.indices {
            let x = Double(input[i])
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            output[i] = Float(y)
            x2 = x1; x1 = x; y2 = y1; y1 = y
        }
        return output
    }

    static func highPass(frequency: Double, sampleRate: Double) -> Biquad {
        let q = 0.70710678, w = 2 * Double.pi * frequency / sampleRate
        let c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0,
                      b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * frequency / sampleRate
        let c = cos(w), s = sin(w), alpha = s / 2 * sqrt(2), root = 2 * sqrt(a) * alpha
        let a0 = (a + 1) - (a - 1) * c + root
        return Biquad(b0: a * ((a + 1) + (a - 1) * c + root) / a0,
                      b1: -2 * a * ((a - 1) + (a + 1) * c) / a0,
                      b2: a * ((a + 1) + (a - 1) * c - root) / a0,
                      a1: 2 * ((a - 1) - (a + 1) * c) / a0,
                      a2: ((a + 1) - (a - 1) * c - root) / a0)
    }
}

private enum EnergyMeter {
    static func curve(_ samples: [Float], sampleRate: Double) -> [Float] {
        let size = max(1, Int(sampleRate))
        var raw: [Float] = []
        for offset in stride(from: 0, to: samples.count, by: size) {
            let end = min(samples.count, offset + size)
            let square = samples[offset..<end].reduce(Float(0)) { $0 + $1 * $1 }
            raw.append(sqrt(square / Float(max(1, end - offset))))
        }
        let sorted = raw.sorted()
        let p95 = sorted.isEmpty ? 1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return raw.map { min(1, max(0, $0 / max(p95, 1e-8))) }
    }

    static func endsInSilence(_ samples: [Float], sampleRate: Double) -> Bool {
        let count = min(samples.count, max(1, Int(sampleRate * 0.5)))
        guard count > 0 else { return true }
        let square = samples.suffix(count).reduce(Float(0)) { $0 + $1 * $1 }
        let rms = sqrt(square / Float(count))
        return 20 * log10(max(rms, 1e-8)) < -40
    }

    static func hasFadeOut(_ samples: [Float], sampleRate: Double) -> Bool {
        let seconds = min(10, Int(Double(samples.count) / sampleRate))
        guard seconds >= 5 else { return false }
        let start = samples.count - Int(Double(seconds) * sampleRate)
        var db: [Float] = []
        for second in 0..<seconds {
            let lo = start + Int(Double(second) * sampleRate)
            let hi = min(samples.count, lo + Int(sampleRate))
            let square = samples[lo..<hi].reduce(Float(0)) { $0 + $1 * $1 }
            db.append(20 * log10(max(sqrt(square / Float(max(1, hi - lo))), 1e-8)))
        }
        let drop = (db.first ?? 0) - (db.last ?? 0)
        let falling = zip(db, db.dropFirst()).filter { $1 <= $0 + 1.5 }.count
        return drop >= 12 && falling >= db.count - 2
    }
}

private enum CueDetector {
    static func segments(energy: [Float], duration: Double, endsSilent: Bool) -> [Segment] {
        guard !energy.isEmpty else { return [Segment(startSec: 0, endSec: duration, type: .unknown)] }
        let first = energy.firstIndex(where: { $0 >= 0.3 }) ?? 0
        let last = energy.lastIndex(where: { $0 >= 0.3 }) ?? max(0, energy.count - 1)
        var result: [Segment] = []
        if first > 0 { result.append(Segment(startSec: 0, endSec: Double(first), type: .intro)) }
        if last > first { result.append(Segment(startSec: Double(first), endSec: Double(last + 1), type: .unknown)) }
        if last + 1 < Int(duration) || endsSilent {
            result.append(Segment(startSec: Double(last + 1), endSec: duration, type: .outro))
        }
        return result.isEmpty ? [Segment(startSec: 0, endSec: duration, type: .unknown)] : result
    }

    static func cues(duration: Double, energy: [Float], downbeats: [Double],
                     phrases: [Double], hasFadeOut: Bool) -> (mixIn: Double, mixOut: Double) {
        let firstEnergy = energy.firstIndex(where: { $0 >= 0.3 }).map(Double.init) ?? 0
        let candidateIn = min(30, firstEnergy)
        let mixIn = nearest(candidateIn, in: downbeats) ?? candidateIn
        let lower = max(0, duration - 60), upper = max(lower, duration - 4)
        let energeticEnd = energy.lastIndex(where: { $0 >= 0.3 }).map { Double($0) } ?? upper
        var candidateOut = hasFadeOut ? max(lower, duration - 10) : min(upper, energeticEnd)
        if let phrase = phrases.last(where: { $0 <= candidateOut }) { candidateOut = phrase }
        else if let beat = downbeats.last(where: { $0 <= candidateOut }) { candidateOut = beat }
        return (mixIn, min(upper, max(lower, candidateOut)))
    }

    static func nearest(_ value: Double, in values: [Double]) -> Double? {
        values.min(by: { abs($0 - value) < abs($1 - value) })
    }
}
